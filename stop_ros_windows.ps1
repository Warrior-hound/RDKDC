$ContainerName = "ros2_jazzy_vnc"

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

$Docker = Resolve-Docker

$ExistingContainers = & $Docker ps -a --format "{{.Names}}"
if ($ExistingContainers -contains $ContainerName) {
    & $Docker stop $ContainerName | Out-Null
    & $Docker rm $ContainerName | Out-Null
}

Write-Host "ROS 2 Jazzy desktop stopped."
