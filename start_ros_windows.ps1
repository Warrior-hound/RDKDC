Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Docker {
    $DockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    if ($DockerCommand) {
        return $DockerCommand.Source
    }

    $DockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $DockerDesktopPath) {
        return $DockerDesktopPath
    }

    Write-Error "Docker was not found. Install Docker Desktop for Windows, start it, then reopen PowerShell so docker.exe is on PATH."
    exit 1
}

$ContainerName = "ros2_jazzy_vnc"
$ImageName = "ros2-jazzy-vnc"
$HostAddress = "127.0.0.1"
$Url = "http://${HostAddress}:6080/vnc_lite.html?autoconnect=true&resize=remote&quality=9&compression=0"
$Docker = Resolve-Docker

$Arch = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
}
else {
    $env:PROCESSOR_ARCHITECTURE
}

switch ($Arch) {
    "ARM64" { $Platform = "linux/arm64" }
    "AMD64" { $Platform = "linux/amd64" }
    default {
        Write-Error "Unsupported Windows architecture: $Arch"
        exit 1
    }
}

$Width = 1920
$Height = 1080

try {
    Add-Type -AssemblyName System.Windows.Forms
    $WorkingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $Width = [int]$WorkingArea.Width
    $Height = [int]$WorkingArea.Height
}
catch {
    Write-Warning "Could not detect screen size; using ${Width}x${Height}."
}

$VncGeometry = "${Width}x${Height}"
$Workspace = Join-Path $HOME "ros2_ws"
$WorkspaceSrc = Join-Path $Workspace "src"

Write-Host "Detected screen: ${Width}x${Height}"
Write-Host "Using VNC geometry: $VncGeometry"

New-Item -ItemType Directory -Force -Path $WorkspaceSrc | Out-Null

$ExistingContainers = & $Docker ps -a --format "{{.Names}}"
if ($ExistingContainers -contains $ContainerName) {
    & $Docker rm -f $ContainerName | Out-Null
}

& $Docker run -d `
    --platform $Platform `
    --name $ContainerName `
    -e "VNC_GEOMETRY=$VncGeometry" `
    -p "127.0.0.1:6080:6080" `
    -p "127.0.0.1:5901:5901" `
    -v "${Workspace}:/root/ros2_ws" `
    $ImageName

Write-Host "Starting ROS 2 Jazzy desktop..."

do {
    Start-Sleep -Seconds 1
    try {
        Invoke-WebRequest -Uri "http://${HostAddress}:6080" -UseBasicParsing -TimeoutSec 1 | Out-Null
        $Ready = $true
    }
    catch {
        $Ready = $false
    }
} until ($Ready)

Start-Process $Url

Write-Host "ROS 2 Jazzy desktop is running."
Write-Host "Workspace on Windows: $Workspace"
Write-Host "Workspace in Docker: /root/ros2_ws"
Write-Host "To stop it: .\stop_ros_windows.ps1"
