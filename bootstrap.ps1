$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Workspace = Split-Path -Parent $PSScriptRoot
if (-not $Workspace -or $Workspace -eq "") {
    $Workspace = (Get-Location).Path
}

function Test-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WinGetExact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ExtraArgs
    )

    $arguments = @(
        "install",
        "--id", $Id,
        "-e",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    if ($ExtraArgs) {
        $arguments += $ExtraArgs
    }

    & winget @arguments
}
function Add-PathDir {
    param([Parameter(Mandatory = $true)][string]$Dir)

    if (-not (Test-Path $Dir)) { return }

    $parts = $env:Path -split ';'
    if ($parts -notcontains $Dir) {
        $env:Path = "$Dir;$env:Path"
        
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if (($userPath -split ';') -notcontains $Dir) {
            [Environment]::SetEnvironmentVariable("Path", "$Dir;$userPath", "User")
        }
    }
}
function Find-ExistingPath {
    param([Parameter(Mandatory = $true)][string[]]$Candidates)

    foreach ($c in $Candidates) {
        $resolved = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved -and $resolved.Exists) { return $resolved.FullName }
    }
    return $null
}

function Ensure-Winget {
    if (-not (Test-Command winget)) {
        throw "winget is missing. Install App Installer first."
    }
}

function Ensure-Java {
    if (Test-Command java) { return }

    try {
        Install-WinGetExact "Microsoft.OpenJDK.25"
    } catch {
        Install-WinGetExact "Microsoft.OpenJDK.21"
    }

    $javaExe = Find-ExistingPath @(
        (Get-ChildItem -Path "$env:ProgramFiles\Java\jdk-*\bin\java.exe" | Select-Object -First 1).FullName

        # "$env:ProgramFiles\Microsoft\jdk-25*\bin\java.exe",
        # "$env:ProgramFiles\Microsoft\jdk-21*\bin\java.exe",
        # "$env:ProgramFiles\Java\jdk-25*\bin\java.exe",
        # "$env:ProgramFiles\Java\jdk-21*\bin\java.exe"
    )

    if (-not $javaExe) {
        throw "Java installed, but java.exe was not found."
    }

    $binDir = Split-Path $javaExe -Parent
    $env:JAVA_HOME = Split-Path $binDir -Parent
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $env:JAVA_HOME, "User")
    Add-PathDir $binDir

    if (-not (Test-Command java)) {
        throw "Java is still not visible in this session."
    }
}

function Ensure-CMake {
    if (Test-Command cmake) { return }

    Install-WinGetExact "Kitware.CMake"

    $cmakeDir = Find-ExistingPath @(
        "$env:ProgramFiles\CMake\bin",
        "${env:ProgramFiles(x86)}\CMake\bin"
    )

    if ($cmakeDir) {
        Add-PathDir $cmakeDir
    }

    if (-not (Test-Command cmake)) {
        throw "CMake is still not visible in this session."
    }
}

function Ensure-VisualStudioBuildTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath
        if ($vsPath) { return }
    }

    Install-WinGetExact "Microsoft.VisualStudio.2022.BuildTools" `
    "--override",
    "--add Microsoft.VisualStudio.Workload.NativeDesktop",
    "--includeRecommended",
    "--passive",
    "--wait"
}
function Ensure-Ollama {
    if (-not (Test-Command ollama)) {
        try {
            winget install --id Ollama.Ollama -e --source winget `
                --accept-package-agreements --accept-source-agreements
        } catch {
            $installer = "$env:TEMP\OllamaSetup.exe"
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installer
            Start-Process -FilePath $installer -ArgumentList "/SILENT" -Wait -NoNewWindow
        }
    }

    $ollamaDir = Find-ExistingPath @(
        "$env:LOCALAPPDATA\Programs\Ollama",
        "$env:ProgramFiles\Ollama"
    )

    if ($ollamaDir) { Add-PathDir $ollamaDir }

    if (-not (Test-Command ollama)) { throw "Ollama installed, but ollama is still not visible." }

    $ollamaUrl = "http://127.0.0.1:11434/api/tags"
    try {
        $resp = Invoke-WebRequest -Uri $ollamaUrl -Method Get -TimeoutSec 2
        if ($resp.StatusCode -eq 200) { return }
    } catch {}

    $ollamaExe = Find-ExistingPath @(
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
        "$env:ProgramFiles\Ollama\ollama.exe"
    )

    if (-not $ollamaExe) { throw "ollama.exe not found after install." }

    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $ollamaUrl -Method Get -TimeoutSec 2
            if ($resp.StatusCode -eq 200) { return }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Ollama did not become reachable on localhost:11434."
}

function Ensure-MavenWrapper {
    $wrapperJar = Join-Path $Workspace ".mvn\wrapper\maven-wrapper.jar"
    $wrapperProps = Join-Path $Workspace ".mvn\wrapper\maven-wrapper.properties"
    $mvnwCmd = Join-Path $Workspace "mvnw.cmd"

    if ((Test-Path $wrapperJar) -and (Test-Path $wrapperProps) -and (Test-Path $mvnwCmd)) {
        return
    }

    # Fallback only if the wrapper is not present.
    if (-not (Test-Command mvn)) {
        try {
            Install-WinGetExact "Apache.Maven"
            $mvnBin = Find-ExistingPath @(
                "$env:ProgramFiles\Apache\Maven\bin",
                "$env:ProgramFiles\Apache\Maven\apache-maven-*\bin"
            )

            if ($mvnBin) {
                Add-PathDir $mvnBin
            }
        } catch {
            throw "Maven Wrapper is missing and Maven install failed."
        }
        if (-not (Test-Command mvn)) {
            throw "Maven installed but mvn not visible (PATH issue)."
        }
    }
}

Ensure-Winget
Ensure-Java
Ensure-CMake
Ensure-VisualStudioBuildTools
Ensure-Ollama
Ensure-MavenWrapper

Write-Host "Bootstrap complete."
Write-Host "JAVA_HOME = $env:JAVA_HOME"
Write-Host "java      = $(Get-Command java | Select-Object -ExpandProperty Source)"
Write-Host "cmake     = $(Get-Command cmake | Select-Object -ExpandProperty Source)"
Write-Host "ollama    = $(Get-Command ollama | Select-Object -ExpandProperty Source)"
if (Test-Command mvn) {
    Write-Host "mvn       = $(Get-Command mvn | Select-Object -ExpandProperty Source)"
} else {
    Write-Host "mvn       = using mvnw.cmd"
}