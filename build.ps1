[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipInstall,
    [switch]$SkipNative,
    [switch]$SkipInstaller,
    [switch]$SkipOllama,
    [switch]$DepsOnly,
    [string]$JavaHome,
    [string]$Configuration = 'Release',
    [string]$AppVersion = '1.0.0',
    [string]$MainClass = 'erudition_program.MainApp',
    [string]$RequiredJavaRelease = '25'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root        = (Resolve-Path $ScriptRoot).Path
$NativeDir   = Join-Path $Root 'native'
$BuildDir    = Join-Path $NativeDir 'build'
$DistDir     = Join-Path $Root 'dist'
$StagingDir  = Join-Path $DistDir 'staging'
$FxModuleDir = Join-Path $StagingDir 'javafx-modules'
$TargetDir   = Join-Path $Root 'target'
$LogPath     = Join-Path $DistDir ('build-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

Set-Location $Root

$script:TranscriptStarted = $false
try {
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    try {
        Start-Transcript -Path $LogPath -Append | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        $script:TranscriptStarted = $false
    }

    function Write-Section([string]$Text) {
        Write-Host ""
        Write-Host "===== $Text ====="
    }

    function Test-Administrator {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Test-Command([string]$Name) {
        return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
    }

    function Add-UserPath([string]$Dir) {
        if (-not (Test-Path $Dir)) { return }

        if (-not (($env:Path -split ';') -contains $Dir)) {
            $env:Path = "$Dir;$env:Path"
        }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $parts = @()
        if ($userPath) { $parts = $userPath -split ';' }
        if ($parts -notcontains $Dir) {
            $newPath = @($Dir) + $parts
            [Environment]::SetEnvironmentVariable('Path', ($newPath -join ';'), 'User')
        }
    }

    function Invoke-WingetInstall {
        param(
            [Parameter(Mandatory = $true)][string]$Label,
            [Parameter(Mandatory = $true)][string[]]$Ids,
            [string]$OverrideArgs = '',
            [switch]$RequireAdmin
        )

        if ($RequireAdmin -and -not (Test-Administrator)) {
            throw "Administrator privileges are required to install $Label."
        }

        foreach ($id in $Ids) {
            Write-Host "Installing $Label using winget id $id"
            $args = @(
                'install',
                '--id', $id,
                '-e',
                '--source', 'winget',
                '--accept-package-agreements',
                '--accept-source-agreements'
            )
            if ($OverrideArgs) {
                $args += @('--override', $OverrideArgs)
            }

            & winget @args
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
            Write-Host "  that id failed, trying the next candidate..."
        }

        return $false
    }

    function Ensure-Winget {
        if (Test-Command winget) { return }
        if ($SkipInstall) {
            throw "winget is missing and -SkipInstall was used."
        }

        Write-Host "winget not found; attempting to register App Installer..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
            'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' | Out-Null

        if (-not (Test-Command winget)) {
            throw "winget still missing. Install App Installer, then re-run."
        }
    }


    function Get-JdkVersionFromPath([string]$Path) {
        $leaf = Split-Path $Path -Leaf
        if ($leaf -match '(?<ver>\d+(?:\.\d+){0,3})') {
            $parts = $Matches['ver'].Split('.')
            while ($parts.Count -lt 4) { $parts += '0' }

            return New-Object System.Version (
            [int]$parts[0],
            [int]$parts[1],
            [int]$parts[2],
            [int]$parts[3]
            )
        }

        return $null
    }

    function Test-JdkHome([string]$homie, [version]$RequiredVersion) {
        if (-not $homie) { return $false }
        $javaExe = Join-Path $homie 'bin\java.exe'
        $javacExe = Join-Path $homie 'bin\javac.exe'
        if (-not (Test-Path $javaExe) -or -not (Test-Path $javacExe)) { return $false }

        try {
            return (Get-JavaVersionFromExe $javaExe) -ge $RequiredVersion
        } catch {
            return $false
        }
    }

    function Get-JdkHomeCandidates {
        $roots = @(
            $env:ProgramFiles,
            ${env:ProgramFiles(x86)}
        ) | Where-Object { $_ } | Select-Object -Unique

        $candidateRoots = @(
            'Java',
            'Oracle',
            'Microsoft',
            'Eclipse Adoptium',
            'Eclipse Temurin',
            'Adoptium'
        )

        $found = @()

        foreach ($root in $roots) {
            foreach ($sub in $candidateRoots) {
                $base = Join-Path $root $sub

                if (-not (Test-Path $base)) {
                    continue
                }

                try {
                    $dirs = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue

                    foreach ($dir in $dirs) {
                        $javaExe  = Join-Path $dir.FullName 'bin\java.exe'
                        $javacExe = Join-Path $dir.FullName 'bin\javac.exe'

                        if ((Test-Path $javaExe) -and (Test-Path $javacExe)) {
                            $found += $dir
                        }
                    }
                } catch {
                }
            }
        }

        return $found | Sort-Object FullName -Unique
    }

    function Find-JdkHome([version]$MinimumVersion) {
        $found = @()

        foreach ($candidate in Get-JdkHomeCandidates) {
            $javaExe  = Join-Path $candidate.FullName 'bin\java.exe'
            $javacExe = Join-Path $candidate.FullName 'bin\javac.exe'

            if (-not (Test-Path $javaExe) -or -not (Test-Path $javacExe)) {
                continue
            }

            $version = Get-JdkVersionFromPath $candidate.FullName
            if (-not $version) {
                continue
            }

            if ($version -ge $MinimumVersion) {
                $found += [pscustomobject]@{
                    Home    = $candidate.FullName
                    Version = $version
                }
            }
        }

        if ($found.Count -gt 0) {
            return ($found | Sort-Object Version -Descending | Select-Object -First 1).Home
        }

        return $null
    }

    function Ensure-JavaRuntime {
        $requiredRelease = [int]$RequiredJavaRelease
        $requiredVersion = [version]::new($requiredRelease, 0, 0, 0)

        if ($JavaHome -and (Test-JdkHome $JavaHome $requiredVersion)) {
            $env:JAVA_HOME = $JavaHome
            Add-UserPath (Join-Path $JavaHome 'bin')
            return $JavaHome
        }

        # Prefer installed JDK discovery first.
        $jdkHome = Find-JdkHome $requiredVersion

        if ($jdkHome) {
            $env:JAVA_HOME = $jdkHome
            Add-UserPath (Join-Path $jdkHome 'bin')
            return $jdkHome
        }

        # Fallback to javac discovery from PATH.
        $javacCmd = Get-Command javac -ErrorAction SilentlyContinue

        if ($javacCmd) {
            try {
                $homie = Split-Path -Parent (Split-Path -Parent $javacCmd.Source)

                if (Test-JdkHome $homie $requiredVersion) {
                    $env:JAVA_HOME = $homie
                    Add-UserPath (Join-Path $homie 'bin')
                    return $homie
                }
            } catch {
            }
        }

        if ($SkipInstall) {
            throw "JDK $RequiredJavaRelease+ not found and -SkipInstall was used."
        }

        Write-Host "Installing JDK $RequiredJavaRelease..."

        $ok = Invoke-WingetInstall `
        -Label "Oracle JDK $RequiredJavaRelease" `
        -Ids @("Oracle.JDK.$RequiredJavaRelease")

        if (-not $ok) {
            throw "Failed to install a JDK."
        }

        Start-Sleep -Seconds 2

        $jdkHome = Find-JdkHome $requiredVersion

        if (-not $jdkHome) {
            throw "JDK $RequiredJavaRelease+ not found after install attempt."
        }

        $env:JAVA_HOME = $jdkHome
        Add-UserPath (Join-Path $jdkHome 'bin')

        return $jdkHome
    }
    

    function Ensure-CMake {
        if (Test-Command cmake) { return $true }

        if ($SkipInstall) {
            throw "CMake is missing and -SkipInstall was used."
        }

        Write-Host "Installing CMake..."
        if (-not (Invoke-WingetInstall -Label 'CMake' -Ids @('Kitware.CMake'))) {
            throw "Failed to install CMake."
        }

        $candidates = @(
            (Join-Path $env:ProgramFiles 'CMake\bin'),
            (Join-Path ${env:ProgramFiles(x86)} 'CMake\bin')
        ) | Where-Object { Test-Path $_ }

        foreach ($dir in $candidates) {
            Add-UserPath $dir
        }

        if (-not (Test-Command cmake)) {
            throw "CMake still not available after install."
        }

        return $true
    }

    function Get-VsWherePath {
        $p = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $p) { return $p }
        return $null
    }

    function Find-VSBuildTools {
        $vswhere = Get-VsWherePath
        if (-not $vswhere) { return $null }

        $path = & $vswhere -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $path) {
            return $path.Trim()
        }

        return $null
    }

    function Ensure-VSBuildTools {
        $vsPath = Find-VSBuildTools
        if ($vsPath) { return $vsPath }

        if ($SkipInstall) {
            throw "Visual Studio Build Tools with C++ workload are missing and -SkipInstall was used."
        }

        Write-Host "Installing Visual Studio 2022 Build Tools with C++ workload..."
        $override = '--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait'
        $ok = Invoke-WingetInstall `
            -Label 'Visual Studio 2022 Build Tools' `
            -Ids @('Microsoft.VisualStudio.2022.BuildTools') `
            -OverrideArgs $override `
            -RequireAdmin

        if (-not $ok) {
            throw "Failed to install Visual Studio Build Tools."
        }

        return (Find-VSBuildTools)
    }

    function Invoke-MavenWrapper {
        param([Parameter(Mandatory = $true)][string[]]$Args)

        $mvnwCmd = Join-Path $Root 'mvnw.cmd'
        $mvnwSh  = Join-Path $Root 'mvnw'

        if (Test-Path $mvnwCmd) {
            & $mvnwCmd @Args
        }
        elseif (Test-Path $mvnwSh) {
            $bash = Get-Command bash -ErrorAction SilentlyContinue
            if (-not $bash) {
                throw "mvnw exists, but bash is not available to run it."
            }
            & $bash.Source $mvnwSh @Args
        }
        else {
            throw "Maven wrapper not found. Commit mvnw.cmd and .mvn/wrapper to the repo."
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Maven wrapper failed with exit code $LASTEXITCODE."
        }
    }

    function Get-MainJar {
        $jar = Get-ChildItem -Path $TargetDir -File -Filter '*.jar' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notlike 'original-*' -and
                $_.Name -notlike '*-sources.jar' -and
                $_.Name -notlike '*-javadoc.jar'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $jar) {
            throw "Main jar not found in target."
        }

        return $jar.FullName
    }

    function Get-NativeDll {
        $dll = Get-ChildItem -Path $BuildDir -Recurse -File -Filter 'gpu_memory_native.dll' -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $dll) {
            throw "Native DLL not found under $BuildDir."
        }

        return $dll.FullName
    }

    function Ensure-Ollama {
        if ($SkipOllama) { return }

        if (Test-Command ollama) {
            try {
                $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 http://127.0.0.1:11434/api/tags
            } catch {
                Write-Host "Starting Ollama..."
                Start-Process -WindowStyle Hidden -FilePath 'ollama' -ArgumentList 'serve' | Out-Null
                Start-Sleep -Seconds 2
            }
            return
        }

        if ($SkipInstall) {
            Write-Host "Ollama is missing; skipped because -SkipInstall was used."
            return
        }

        Write-Host "Installing Ollama..."
        $ok = Invoke-WingetInstall -Label 'Ollama' -Ids @('Ollama.Ollama')
        if (-not $ok) {
            Write-Host "Ollama install failed; app may require it at runtime."
            return
        }

        $ollamaDir = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Ollama'),
            (Join-Path ${env:ProgramFiles} 'Ollama'),
            (Join-Path ${env:ProgramFiles(x86)} 'Ollama')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($ollamaDir) {
            Add-UserPath $ollamaDir
        }
    }

    function Ensure-WiX {
        if (Test-Command candle) { return $true }
        if (Test-Command wix) { return $true }   # WiX v4

        if ($SkipInstall) {
            throw "WiX Toolset is missing and -SkipInstall was used."
        }

        Write-Host "Installing WiX Toolset..."
        $ok = Invoke-WingetInstall -Label 'WiX Toolset' -Ids @(
            'WiXToolset.WiXToolset',
            'WiXToolset.WiXCLI'
        )
        if (-not $ok) {
            return $false
        }

        $wixDirs = @(
            (Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.11\bin'),
            (Join-Path ${env:ProgramFiles} 'WiX Toolset v3.11\bin'),
            (Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14\bin'),
            (Join-Path ${env:ProgramFiles} 'WiX Toolset v3.14\bin')
        ) | Where-Object { Test-Path $_ }

        foreach ($dir in $wixDirs) {
            Add-UserPath $dir
        }

        return (Test-Command candle) -or (Test-Command wix)
    }

    function Ensure-JavaFxSdk {
        $fxVersion = "26.0.1"
        $fxDir = Join-Path $Root "javafx-sdk-$fxVersion"
        if (Test-Path $fxDir) {
            Write-Host "JavaFX SDK $fxVersion already present at $fxDir."
            return $fxDir
        }

        Write-Host "Downloading JavaFX SDK $fxVersion..."
        $zipUrl = "https://download2.gluonhq.com/openjfx/$fxVersion/openjfx-${fxVersion}_windows-x64_bin-sdk.zip"
        $zipPath = Join-Path $Root "openjfx-$fxVersion.zip"

        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            Write-Host "Extracting JavaFX SDK..."
            Expand-Archive -Path $zipPath -DestinationPath $Root -Force
            
            $extracted = Join-Path $Root "javafx-sdk-$fxVersion"
            if (-not (Test-Path $extracted)) {
                $unzippedFolder = Get-ChildItem -Path $Root -Directory -Filter "javafx-sdk-*" | Select-Object -First 1
                if ($unzippedFolder) {
                    Rename-Item -Path $unzippedFolder.FullName -NewName "javafx-sdk-$fxVersion"
                }
            }
            Write-Host "JavaFX SDK $fxVersion successfully downloaded and extracted."
        }
        finally {
            if (Test-Path $zipPath) {
                Remove-Item $zipPath -Force
            }
        }
        return $fxDir
    }

    function Ensure-Directory([string]$Path) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }

    function Build-Native {
        Write-Section 'Native build'
        Ensure-Directory $BuildDir

        & cmake -S $NativeDir -B $BuildDir -G 'Visual Studio 17 2022' -A x64
        if ($LASTEXITCODE -ne 0) {
            throw "cmake configure failed."
        }

        & cmake --build $BuildDir --config $Configuration -- /m
        if ($LASTEXITCODE -ne 0) {
            throw "cmake build failed."
        }
    }

    function Build-Java {
        Write-Section 'Java build'
        Ensure-Directory $StagingDir
        Ensure-Directory $FxModuleDir

        Invoke-MavenWrapper @('-q', '-DskipTests', 'package')
        Invoke-MavenWrapper @(
            '-q',
            '-DskipTests',
            'dependency:copy-dependencies',
            "-DincludeScope=runtime",
            "-DoutputDirectory=$StagingDir"
        )

        $mainJar = Get-MainJar
        Copy-Item $mainJar -Destination (Join-Path $StagingDir 'app.jar') -Force
    }

    function Stage-NativeDll {
        $dll = Get-NativeDll
        Copy-Item $dll -Destination (Join-Path $StagingDir 'gpu_memory_native.dll') -Force
    }

    function Prepare-JavaFxModulePath {
        Remove-Item $FxModuleDir -Recurse -Force -ErrorAction SilentlyContinue
        Ensure-Directory $FxModuleDir

        $localSdkLib = Join-Path $Root "javafx-sdk-26.0.1\lib"
        if (Test-Path $localSdkLib) {
            Write-Host "Using manually downloaded JavaFX SDK components..."
            Copy-Item (Join-Path $localSdkLib "javafx-*.jar") -Destination $FxModuleDir -Force
        } else {
            $javaFxJars = Get-ChildItem -Path $StagingDir -File -Filter 'javafx-*.jar' -ErrorAction SilentlyContinue
            if (-not $javaFxJars -or $javaFxJars.Count -eq 0) {
                throw "No JavaFX jars were found in $StagingDir."
            }
            foreach ($jar in $javaFxJars) {
                Copy-Item $jar.FullName -Destination $FxModuleDir -Force
            }
        }

        $paths = Get-ChildItem -Path $FxModuleDir -File -Filter '*.jar' |
            Sort-Object Name |
            ForEach-Object { $_.FullName }

        return ($paths -join ';')
    }

    function Build-Installer {
        Write-Section 'Installer packaging'

        if (-not (Ensure-WiX)) {
            throw "WiX Toolset is required for jpackage .exe output and was not found."
        }

        $jpackage = Join-Path $env:JAVA_HOME 'bin\jpackage.exe'
        if (-not (Test-Path $jpackage)) {
            $cmd = Get-Command jpackage -ErrorAction SilentlyContinue
            if ($cmd) {
                $jpackage = $cmd.Source
            }
        }

        if (-not (Test-Path $jpackage)) {
            throw "jpackage was not found under JAVA_HOME."
        }

        $modulePath = Prepare-JavaFxModulePath

        $icon = Join-Path $Root 'app.ico'
        $iconArgs = @()
        if (Test-Path $icon) {
            $iconArgs += @('--icon', $icon)
        }

        & $jpackage `
            --type exe `
            --name 'Erudition-AI' `
            --app-version $AppVersion `
            --input $StagingDir `
            --main-jar 'app.jar' `
            --main-class $MainClass `
            --dest $DistDir `
            --win-console `
            --module-path $modulePath `
            --add-modules 'javafx.controls' `
            --java-options '-Dnative.dir=$APPDIR' `
            @iconArgs

        if ($LASTEXITCODE -ne 0) {
            throw "jpackage failed."
        }
    }

    if (-not $DepsOnly -and -not $SkipNative -and -not $SkipInstaller) {
        $choice = Read-Host "1. Install Dependencies and Build Executable `n 2. Install Dependencies Only `n [1/2]"
        if ($choice -match '^(2|two)$') {
            $DepsOnly = $true
        }
    }

    Write-Section 'Environment'
    if (-not $SkipInstall) {
        Ensure-Winget
    }

    $javaHome = Ensure-JavaRunTime
    Ensure-CMake | Out-Null
    $vsPath = Ensure-VSBuildTools
    Ensure-Ollama
    Ensure-JavaFxSdk

    if ($DepsOnly) {
        Write-Host ""
        Write-Host "Dependencies installed."
        exit 0
    }

    $cmakePath = (Get-Command cmake).Source
    $javaPath  = (Get-Command java).Source

    Write-Host "JAVA_HOME = $javaHome"
    Write-Host "java      = $javaPath"
    Write-Host "cmake     = $cmakePath"
    Write-Host ("vs tools  = {0}" -f ($(if ($vsPath) { $vsPath } else { 'missing' })))
    Write-Host ("ollama    = {0}" -f ($(if (Test-Command ollama) { (Get-Command ollama).Source } else { 'missing' })))
    Write-Host ("mvnw      = {0}" -f ($(if (Test-Path (Join-Path $Root 'mvnw.cmd')) { 'mvnw.cmd' } elseif (Test-Path (Join-Path $Root 'mvnw')) { 'mvnw' } else { 'missing' })))

    if ($Clean) {
        Write-Section 'Clean'
        Remove-Item $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $DistDir  -Recurse -Force -ErrorAction SilentlyContinue
        Ensure-Directory $DistDir
    }
    if($DepsOnly){
        Write-Host "...Installing dependencies only..."
        Write-Host "ignoring native build, Java package, installer."
    }
    else{
        if (-not $SkipNative) {
            Build-Native
        } else {
            Write-Host "Skipping native build."
        }

        Build-Java
        Stage-NativeDll

        if (-not $SkipInstaller) {
            if (-not (Test-Path (Join-Path $StagingDir 'app.jar'))) {
                throw "app.jar is missing from staging."
            }
            if (-not (Test-Path (Join-Path $StagingDir 'gpu_memory_native.dll'))) {
                throw "gpu_memory_native.dll is missing from staging."
            }
            Build-Installer
            Write-Host ""
            Write-Host "Build complete."
            Write-Host ("Installer: {0}" -f (Join-Path $DistDir ("Erudition-AI-{0}.exe" -f $AppVersion)))
        } else {
            Write-Host ""
            Write-Host "Build complete."
            Write-Host ("Staging: {0}" -f $StagingDir)
        }
    }

    Write-Host ""
    Write-Host ("Log: {0}" -f $LogPath)
}
finally {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}