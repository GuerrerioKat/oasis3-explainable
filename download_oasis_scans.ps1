param(
    [Parameter(Mandatory=$true)]
    [string]$InputCsv,

    [Parameter(Mandatory=$true)]
    [string]$OutputDir,

    [Parameter(Mandatory=$true)]
    [string]$Username,

    [Parameter(Mandatory=$false)]
    [string]$ScanType = "ALL",

    [Parameter(Mandatory=$false)]
    [string]$TauProjectId
)

# Ensure output directory exists
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# Prompt for password securely
$SecurePassword = Read-Host "Enter your NITRC password" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

# Create web session
$Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# Login to XNAT
$loginUrl = "https://www.nitrc.org/ir/data/JSESSION"
try {
    Invoke-WebRequest -Uri $loginUrl `
        -Method GET `
        -WebSession $Session `
        -Credential (New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)) `
        -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "Login failed. Check username/password."
    exit 1
}

Write-Host "Login successful."

# Import CSV
$rows = Import-Csv $InputCsv

foreach ($row in $rows) {

    $experimentId = $row.experiment_id.Trim()
    $subjectId = $experimentId.Split("_")[0]

    if ($ScanType -ne "ALL") {
        Write-Host "Checking for $ScanType scan for $experimentId"
    } else {
        Write-Host "Downloading all scans for $experimentId"
    }

    # Determine project
    $projectId = "OASIS3"

    if ($experimentId.StartsWith("OAS4")) {
        $projectId = "OASIS4"
    }

    if ($experimentId -match "_AV1451") {
        if ($TauProjectId -eq "OASIS3_AV1451" -or $TauProjectId -eq "OASIS3_AV1451L") {
            $projectId = $TauProjectId
        }
        else {
            $projectId = "OASIS3_AV1451"
        }
    }

    # Construct download URL
    $downloadUrl = "https://www.nitrc.org/ir/data/archive/projects/$projectId/subjects/$subjectId/experiments/$experimentId/scans/$ScanType/files?format=zip"

    Write-Host $downloadUrl

    $zipPath = Join-Path $OutputDir "$experimentId.zip"

    try {
        Invoke-WebRequest -Uri $downloadUrl `
            -WebSession $Session `
            -OutFile $zipPath `
            -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to download $experimentId"
        continue
    }

    # Check if zip valid
    if ((Test-Path $zipPath) -and ((Get-Item $zipPath).Length -gt 5000)) {

        Write-Host "Download complete. Extracting..."

        Expand-Archive -Path $zipPath -DestinationPath $OutputDir -Force

        $scanRoot = Join-Path $OutputDir $experimentId
        $scansPath = Join-Path $scanRoot "scans"

        if (Test-Path $scansPath) {

            Get-ChildItem $scansPath -Directory | ForEach-Object {

                $scanNameAll = $_.Name
                $scanName = $scanNameAll.Split("-")[0]

                $destDir = Join-Path $scanRoot $scanName

                if (!(Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir | Out-Null
                }

                Get-ChildItem "$($_.FullName)\resources\*\files\*" -Recurse |
                    Move-Item -Destination $destDir -Force
            }

            Remove-Item $scansPath -Recurse -Force
        }

        Remove-Item $zipPath -Force

        Write-Host "Done with $experimentId"
    }
    else {
        Write-Host "No valid scan found for $experimentId"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }
}

# Logout
Invoke-WebRequest `
    -Uri "https://www.nitrc.org/ir/data/JSESSION" `
    -Method DELETE `
    -WebSession $Session | Out-Null

Write-Host "Session ended."