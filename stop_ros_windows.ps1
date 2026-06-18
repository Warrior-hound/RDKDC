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

    throw "Docker was not found. Install Docker Desktop for Windows, start it, then reopen PowerShell."
}

$Docker = Resolve-Docker
$ContainerName = "rdkdc_ros2_jazzy"

& $Docker rm -f $ContainerName *> $null

Write-Host "RDKDC ROS 2 Jazzy Docker container stopped."
