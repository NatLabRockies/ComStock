<#
.SYNOPSIS
    Builds the ComStock OpenStudio Apptainer image following the steps in build/README.md,
    verifies it, and uploads it to Kestrel.

.DESCRIPTION
    1. Builds the 'apptainer' builder image (build/apptainer/Dockerfile).
    2. Pulls registry:2 and creates the 'registry' container, skipping whatever already exists,
       and starts the container if it exists but is not running.
    3. Builds the OpenStudio container (build/Dockerfile), tags it, and pushes it to the local registry.
    4. Runs build_apptainer.sh inside the builder container to produce build/docker-openstudio.sif.
    5. Renames the sif to OpenStudio-{Tag}.{commit}-Apptainer.sif, where {commit} is the first 12
       characters of the comstock-typical ref in resources/Gemfile.
    6. Runs `openstudio gem_list` inside the sif and checks that comstock-typical resolves to {commit}.
    7. Copies the sif to the Kestrel image directory over ssh, refusing to overwrite an existing image.
       The file is uploaded under a .partial name, size-checked, then moved into place.

    If the build succeeds but the upload fails (e.g. no connection), rerun with -UploadLatest to verify
    and upload the most recently built sif in build/ without rebuilding.

.PARAMETER Tag
    SIF version name, e.g. os_310_typ_010.

.PARAMETER Force
    Overwrite an existing local sif with the same final name. Never overwrites the image on Kestrel.

.PARAMETER NoUpload
    Build and verify only; skip the Kestrel upload.

.PARAMETER UploadLatest
    Skip the build. Verify and upload the newest OpenStudio-*-Apptainer.sif in build/.

.PARAMETER SshHost
    ssh host (or ~/.ssh/config alias) for Kestrel. Must authenticate without a prompt.

.PARAMETER RemoteDir
    Destination directory on Kestrel.

.EXAMPLE
    .\build\build_apptainer_image.ps1 -Tag os_310_typ_010

.EXAMPLE
    .\build\build_apptainer_image.ps1 -UploadLatest
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build', Mandatory = $true, Position = 0)]
    [string]$Tag,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$NoUpload,

    [Parameter(ParameterSetName = 'UploadLatest', Mandatory = $true)]
    [switch]$UploadLatest,

    [string]$SshHost = 'hpc',

    [string]$RemoteDir = '/kfs2/shared-projects/buildstock/apptainer_images'
)

$ErrorActionPreference = 'Stop'

$buildDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $buildDir
$gemfile = Join-Path $repoRoot 'resources\Gemfile'
$registryName = 'registry'
$registryImage = 'registry:2'
$localImage = '127.0.0.1:5000/docker-openstudio:latest'
$sshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'LogLevel=ERROR')

function Invoke-Docker {
    # Runs docker with the given arguments and stops the script on a non-zero exit code.
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($args -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Probe {
    # Runs a native command, returning its stdout and leaving the exit code in $LASTEXITCODE.
    # stderr is discarded; ErrorActionPreference is relaxed so Windows PowerShell 5.1 does not
    # turn native stderr output into a terminating error. Uses $args rather than a param block so
    # flags such as -f and -o pass through to the native command instead of binding here.
    # $rest must stay an array: splatting a lone string passes it one character at a time.
    $exe = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @rest 2> $null
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Assert-DockerRunning {
    Invoke-Probe docker info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker daemon is not reachable. Start Docker Desktop and try again.'
    }
}

function Test-RemoteImage {
    # Returns 'absent' if the image can be uploaded, 'exists' if it is already on Kestrel,
    # or 'unreachable' if ssh failed. Throws if the remote directory is missing or not writable.
    param([string]$Name)
    $remoteCmd = "test -d '{0}' && test -w '{0}' || exit 3; test -e '{0}/{1}' && exit 4; exit 0" -f $RemoteDir, $Name
    Invoke-Probe ssh @sshOptions $SshHost $remoteCmd | Out-Null
    switch ($LASTEXITCODE) {
        0 { return 'absent' }
        4 { return 'exists' }
        3 { throw "Remote directory $RemoteDir does not exist or is not writable on $SshHost." }
        default { return 'unreachable' }
    }
}

function Test-ImageCommit {
    # Runs `openstudio gem_list` inside the sif (via the apptainer builder container) and checks
    # that the comstock-typical gem was installed from the expected commit.
    param([string]$Name, [string]$ExpectedCommit)
    Write-Host "`n=== Verifying comstock-typical commit in $Name ===" -ForegroundColor Cyan
    $inner = "apptainer exec '$Name' openstudio --bundle /var/oscli/Gemfile --bundle_path /var/oscli/gems --bundle_without test gem_list 2>&1"
    $output = Invoke-Probe docker run --rm --privileged -v "${buildDir}:/root/build" apptainer sh -c $inner
    $exitCode = $LASTEXITCODE
    $gemLine = $output | Where-Object { $_ -match '^\s*comstock-typical\s' } | Select-Object -First 1
    if ($exitCode -ne 0 -or -not $gemLine) {
        $output | Write-Host
        throw "Could not list gems in $Name (exit code $exitCode)."
    }
    Write-Host $gemLine.Trim()
    if ($gemLine -notmatch 'ComStock-Typical-([0-9a-fA-F]+)') {
        throw 'Could not read the comstock-typical commit from the gem path.'
    }
    $found = $Matches[1]
    if (-not ($found.StartsWith($ExpectedCommit) -or $ExpectedCommit.StartsWith($found))) {
        throw "comstock-typical commit in image is $found, expected $ExpectedCommit. Not uploading."
    }
    Write-Host "comstock-typical commit $found matches." -ForegroundColor Green
}

function Publish-Image {
    # Copies the sif to Kestrel. Returns $true on success, $false if the connection failed.
    param([string]$Name)
    Write-Host "`n=== Uploading $Name to ${SshHost}:$RemoteDir ===" -ForegroundColor Cyan
    $localPath = Join-Path $buildDir $Name
    $size = (Get-Item $localPath).Length

    $state = Test-RemoteImage $Name
    if ($state -eq 'exists') {
        throw "$Name already exists in $RemoteDir on $SshHost. Not overwriting it; build with a different -Tag."
    }
    if ($state -eq 'unreachable') {
        return $false
    }

    # Upload under a temporary name so an interrupted copy never looks like a finished image.
    # scp runs from the build directory so the Windows drive letter is not parsed as a host.
    Push-Location $buildDir
    try {
        & scp @sshOptions $Name "${SshHost}:$RemoteDir/$Name.partial"
        $scpExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($scpExit -ne 0) {
        Write-Warning "scp failed with exit code $scpExit."
        return $false
    }

    $finalize = ("cd '{0}' || exit 3; " +
        "test `$(stat -c %s '{1}.partial') -eq {2} || {{ echo 'size mismatch after upload'; exit 5; }}; " +
        "test -e '{1}' && {{ echo 'image appeared during upload'; exit 4; }}; " +
        "mv '{1}.partial' '{1}' && chmod 664 '{1}' && ls -l '{1}'") -f $RemoteDir, $Name, $size
    & ssh @sshOptions $SshHost $finalize | Write-Host
    switch ($LASTEXITCODE) {
        0 { }
        5 { throw "Uploaded size does not match the local $size bytes; $RemoteDir/$Name.partial left in place." }
        4 { throw "$Name appeared in $RemoteDir during the upload; $RemoteDir/$Name.partial left in place." }
        255 { Write-Warning 'Lost the connection while finalizing the upload.'; return $false }
        default { throw "Finalizing the upload failed with exit code $LASTEXITCODE." }
    }
    Write-Host "Uploaded $RemoteDir/$Name" -ForegroundColor Green
    return $true
}

function Complete-Upload {
    param([string]$Name)
    if (-not (Publish-Image $Name)) {
        Write-Warning ("Could not reach $SshHost. The image is built and verified at $(Join-Path $buildDir $Name). " +
            "Rerun with -UploadLatest once the connection is available.")
        exit 1
    }
}

# ---------------------------------------------------------------------------------------------
# Upload-only mode
# ---------------------------------------------------------------------------------------------
if ($UploadLatest) {
    $latest = Get-ChildItem -Path $buildDir -Filter 'OpenStudio-*-Apptainer.sif' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "No OpenStudio-*-Apptainer.sif found in $buildDir."
    }
    if ($latest.Name -notmatch '^OpenStudio-.+\.([0-9a-fA-F]{12})-Apptainer\.sif$') {
        throw "Cannot read a 12-character commit from $($latest.Name)."
    }
    $commit = $Matches[1]
    Write-Host "Latest image: $($latest.Name) (built $($latest.LastWriteTime))"

    Assert-DockerRunning
    Test-ImageCommit $latest.Name $commit
    Complete-Upload $latest.Name
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Build mode
# ---------------------------------------------------------------------------------------------

# Resolve the comstock-typical commit from the Gemfile (uncommented gem line with a git ref)
$gemLine = Get-Content $gemfile | Where-Object { $_ -match "^\s*gem\s+'comstock-typical'" }
if (-not $gemLine) {
    throw "No active comstock-typical gem line found in $gemfile"
}
if ($gemLine -notmatch "ref:\s*'([0-9a-fA-F]+)'") {
    throw "The active comstock-typical gem line has no git ref (is it pointing at a local path?):`n$gemLine"
}
$commit = $Matches[1].Substring(0, 12)
$sifName = "OpenStudio-$Tag.$commit-Apptainer.sif"
$sifPath = Join-Path $buildDir $sifName
Write-Host "comstock-typical commit: $commit"
Write-Host "Output image: $sifPath"

if ((Test-Path $sifPath) -and -not $Force) {
    throw "$sifName already exists. Use -Force to overwrite it."
}

# Fail before a long build if the image name is already taken on Kestrel
if (-not $NoUpload) {
    $remoteState = Test-RemoteImage $sifName
    if ($remoteState -eq 'exists') {
        throw "$sifName already exists in $RemoteDir on $SshHost. Use a different -Tag, or -NoUpload."
    }
    if ($remoteState -eq 'unreachable') {
        Write-Warning "Could not reach $SshHost now; building anyway and retrying the upload at the end."
    }
}

Assert-DockerRunning

Push-Location $repoRoot
try {
    # Build the apptainer builder image
    Write-Host "`n=== Building apptainer builder image ===" -ForegroundColor Cyan
    Invoke-Docker build -t apptainer -f build/apptainer/Dockerfile ./build

    # Registry image: pull only if missing
    Write-Host "`n=== Checking local registry ===" -ForegroundColor Cyan
    Invoke-Probe docker image inspect $registryImage | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pulling $registryImage"
        Invoke-Docker pull $registryImage
    } else {
        Write-Host "$registryImage already present, skipping pull"
    }

    # Registry container: create if missing, start if stopped
    $state = Invoke-Probe docker container inspect -f '{{.State.Running}}' $registryName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating and starting '$registryName' container"
        Invoke-Docker run -d -p 5000:5000 --name $registryName $registryImage
    } elseif ($state -ne 'true') {
        Write-Host "Starting existing '$registryName' container"
        Invoke-Docker start $registryName
    } else {
        Write-Host "'$registryName' container already running"
    }

    # Build OpenStudio container and push to the local registry
    Write-Host "`n=== Building OpenStudio container ===" -ForegroundColor Cyan
    Invoke-Docker build -t docker-openstudio -f build/Dockerfile --progress plain .
    Invoke-Docker tag docker-openstudio:latest $localImage
    Invoke-Docker push $localImage
} finally {
    Pop-Location
}

# Build the sif inside the builder container; build_apptainer.sh writes build/docker-openstudio.sif
Write-Host "`n=== Building Apptainer image ===" -ForegroundColor Cyan
$defaultSif = Join-Path $buildDir 'docker-openstudio.sif'
if (Test-Path $defaultSif) {
    Remove-Item $defaultSif
}
Push-Location $buildDir
try {
    Invoke-Docker run --rm --privileged `
        -v "${buildDir}:/root/build" `
        -v /var/run/docker.sock:/var/run/docker.sock `
        --network "container:$registryName" `
        apptainer /root/build/apptainer/build_apptainer.sh
} finally {
    Pop-Location
}

if (-not (Test-Path $defaultSif)) {
    throw "Apptainer build finished but $defaultSif was not created."
}

Move-Item -Path $defaultSif -Destination $sifPath -Force
Write-Host "`nBuilt: $sifPath" -ForegroundColor Green

Test-ImageCommit $sifName $commit

if ($NoUpload) {
    Write-Host 'Skipping upload (-NoUpload).'
    exit 0
}
Complete-Upload $sifName
