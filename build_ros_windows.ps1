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

$ImageName = "ros2-jazzy-vnc"
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

Write-Host "Detected Windows architecture: $Arch"
Write-Host "Using Docker platform: $Platform"

& $Docker build `
    --platform $Platform `
    -t $ImageName .

Write-Host "Build complete."
