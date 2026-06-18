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

function Get-DockerPlatform {
    $Arch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($Arch) {
        "ARM64" { return "linux/arm64" }
        "AMD64" { return "linux/amd64" }
        default { throw "Unsupported Windows architecture: $Arch" }
    }
}

$ImageName = "ros2-jazzy-vnc"
$Docker = Resolve-Docker
$Platform = Get-DockerPlatform

Write-Host "Detected Docker platform: $Platform"
Write-Host "Building $ImageName..."

& $Docker build --platform $Platform -t $ImageName .

Write-Host "Build complete."
