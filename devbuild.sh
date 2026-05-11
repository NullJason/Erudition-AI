#!/usr/bin/env bash
set -euo pipefail

# ───────────── devbuild.sh – Environment setup for Erudition-AI ─────────────
#  • Java 21+ (Microsoft OpenJDK)
#  • CMake
#  • Visual Studio 2022 Build Tools (C++ workload)
#  • Maven (wrapper preference, system fallback)
#  • Ollama (optional AI backend)
#  • WiX (for jpackage .exe output)
#  • Repairs JAVA_HOME & PATH when necessary
#  • Administrator check for winget installs
# ─────────────────────────────────────────────────────────────────────────────

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$ROOT/native"
BUILD_DIR="$NATIVE_DIR/build"
DIST_DIR="$ROOT/dist"
STAGING_DIR="$DIST_DIR/staging"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------------------------------------------------------------------
# Administrator check (only for winget operations)
# -------------------------------------------------------------------
check_admin() {
    # Check if running as admin in Windows (Git Bash)
    net session >/dev/null 2>&1 && return 0 || return 1
}

# -------------------------------------------------------------------
# Add a directory to the current PATH and user's permanent PATH
# -------------------------------------------------------------------
add_path() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
    if need_cmd setx; then
        powershell.exe -NoProfile -Command \
            "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$dir', 'User')" >/dev/null 2>&1 || true
    fi
}

# -------------------------------------------------------------------
# Locate a JDK 21+ and return its Unix-style path (or Windows if no cygpath)
# -------------------------------------------------------------------
find_java_home() {
    local win_home
    win_home="$(powershell.exe -NoProfile -Command '
        $candidates = @(
            (Join-Path $env:ProgramFiles "Microsoft\jdk-2[1-9]*"),
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\jdk-2[1-9]*"),
            (Join-Path $env:ProgramFiles "Java\jdk-2[1-9]*")
        )
        foreach ($p in $candidates) {
            $found = Get-Item $p -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { Write-Output $found.FullName; exit 0 }
        }
        exit 1
    ' | tr -d '\r')"

    if need_cmd cygpath; then
        cygpath -u "$win_home"
    else
        echo "$win_home"
    fi
}

# -------------------------------------------------------------------
# Install a winget package with error output and admin fallback
# -------------------------------------------------------------------
winget_install() {
    local label="$1"; shift
    local ids=("$@")

    if ! check_admin; then
        echo "⚠  Administrator privileges required to install $label via winget."
        echo "   Restart this script from an elevated terminal, or install manually and re-run."
        return 1
    fi

    for id in "${ids[@]}"; do
        echo "   Trying: winget install --id $id ..."
        # Run without silent suppression so errors are visible
        if winget install --id "$id" -e --source winget \
            --accept-package-agreements --accept-source-agreements; then
            echo "✓ Installed $label ($id)"
            return 0
        fi
        echo "   That ID failed, trying next..."
    done
    echo "✗ Failed to install $label. Last error above." >&2
    return 1
}

# -------------------------------------------------------------------
# MAIN SETUP
# -------------------------------------------------------------------
echo "===== devbuild: environment check ====="

# Ensure winget is present
if ! need_cmd winget; then
    echo "winget not found – attempting to install App Installer..."
    powershell.exe -NoProfile -Command \
        "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" || {
        echo "Cannot proceed without winget. Install it manually and re-run." >&2
        exit 1
    }
fi

# ── Java ────────────────────────────────────────────────────────────────────
echo "Checking Java..."
if need_cmd java; then
    echo "  java found at $(command -v java)"
else
    echo "  Installing OpenJDK 25 (or 21) via winget..."
    winget_install "OpenJDK" "Microsoft.OpenJDK.25" "Microsoft.OpenJDK.21"
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
    JAVA_HOME=$(find_java_home)
fi
if [[ -z "$JAVA_HOME" || ! -f "$JAVA_HOME/bin/java.exe" ]]; then
    echo "FATAL: JDK not found after install attempt." >&2
    exit 1
fi

export JAVA_HOME
add_path "$JAVA_HOME/bin"
echo "  JAVA_HOME=$JAVA_HOME"

# ── CMake ───────────────────────────────────────────────────────────────────
echo "Checking CMake..."
if ! need_cmd cmake; then
    winget_install "CMake" "Kitware.CMake"
    CMAKE_DIR="$(powershell.exe -NoProfile -Command '
        Join-Path $env:ProgramFiles "CMake\bin"
    ' | tr -d '\r')"
    # Convert to Unix path if possible
    if need_cmd cygpath; then CMAKE_DIR=$(cygpath -u "$CMAKE_DIR"); fi
    if [[ -d "$CMAKE_DIR" ]]; then
        add_path "$CMAKE_DIR"
    fi
fi
if need_cmd cmake; then
    echo "  cmake found at $(command -v cmake)"
else
    echo "FATAL: cmake still not found." >&2
    exit 1
fi

# ── Visual Studio Build Tools ───────────────────────────────────────────────
echo "Checking Visual Studio Build Tools..."
VSWWHERE="$(powershell.exe -NoProfile -Command '
    Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
' | tr -d '\r')"

if [[ -f "$VSWWHERE" ]]; then
    VS_PATH="$("$VSWWHERE" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>/dev/null || true)"
fi

if [[ -z "${VS_PATH:-}" ]]; then
    echo "  Installing Visual Studio 2022 Build Tools with C++ workload..."
    winget install --id "Microsoft.VisualStudio.2022.BuildTools" -e --source winget \
        --accept-package-agreements --accept-source-agreements \
        --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait" || true
fi

# Re‑evaluate
if [[ -f "$VSWWHERE" ]]; then
    VS_PATH="$("$VSWWHERE" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>/dev/null || true)"
fi

if [[ -n "${VS_PATH:-}" ]]; then
    echo "  Visual Studio at: $VS_PATH"
else
    echo "  WARNING: Visual Studio Build Tools may still be missing. Native build may fail."
fi

# ── Maven (wrapper) ────────────────────────────────────────────────────────
echo "Checking Maven wrapper..."
MVN_CMD="$ROOT/mvnw"
MVN_WRAPPER_JAR="$ROOT/.mvn/wrapper/maven-wrapper.jar"
MVN_WRAPPER_PROPS="$ROOT/.mvn/wrapper/maven-wrapper.properties"

has_wrapper() {
    [[ -f "$MVN_WRAPPER_JAR" && -f "$MVN_WRAPPER_PROPS" && -f "$MVN_CMD" ]]
}

if has_wrapper; then
    echo "  Maven wrapper present"
else
    echo "  Maven wrapper missing."
    # Try to install system Maven first
    if winget_install "Apache Maven" "Apache.Maven"; then
        MAVEN_BIN="$(powershell.exe -NoProfile -Command '
            Join-Path $env:ProgramFiles "Apache\Maven\bin"
        ' | tr -d '\r')"
        if need_cmd cygpath; then MAVEN_BIN=$(cygpath -u "$MAVEN_BIN"); fi
        if [[ -d "$MAVEN_BIN" ]]; then
            add_path "$MAVEN_BIN"
            echo "  mvn available at $(command -v mvn)"
        fi
    else
        echo "  System Maven installation failed. Downloading Maven wrapper instead..."
        # Download maven-wrapper.jar and properties directly
        mkdir -p "$ROOT/.mvn/wrapper"
        if need_cmd curl; then
            curl -sL "https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar" -o "$MVN_WRAPPER_JAR"
        elif need_cmd wget; then
            wget -q "https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar" -O "$MVN_WRAPPER_JAR"
        else
            echo "ERROR: cannot download wrapper (no curl/wget)." >&2; exit 1
        fi
        # Create maven-wrapper.properties with a recent Maven version
        cat > "$MVN_WRAPPER_PROPS" <<EOF
distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.6/apache-maven-3.9.6-bin.zip
wrapperUrl=https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar
EOF
        # Create a minimal mvnw.cmd if missing (Windows batch wrapper)
        if [[ ! -f "$MVN_CMD" ]]; then
            echo "@REM Maven wrapper script" > "$MVN_CMD"
            echo "@setlocal" >> "$MVN_CMD"
            echo "set MAVEN_HOME=%USERPROFILE%\.m2\wrapper\dists\apache-maven-3.9.6-bin\1uk9md6f3f5pafg4js7u5j6n7p" >> "$MVN_CMD"
            echo "call %MAVEN_HOME%\bin\mvn.cmd %*" >> "$MVN_CMD"
        fi
        echo "  Maven wrapper files created. Use ./mvnw to build."
    fi
fi

# ── Ollama (AI backend) ─────────────────────────────────────────────────────
echo "Checking Ollama..."
if need_cmd ollama; then
    echo "  ollama found"
else
    echo "  Installing Ollama..."
    winget_install "Ollama" "Ollama.Ollama"
    if ! need_cmd ollama; then
        # Direct download fallback
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
            "Invoke-WebRequest -Uri https://ollama.com/download/OllamaSetup.exe -OutFile $env:TEMP\OllamaSetup.exe; Start-Process -FilePath $env:TEMP\OllamaSetup.exe -ArgumentList '/SILENT' -Wait" || true
    fi
    OLLAMA_DIR="$(powershell.exe -NoProfile -Command '
        Join-Path $env:LOCALAPPDATA "Programs\Ollama"
    ' | tr -d '\r')"
    if need_cmd cygpath; then OLLAMA_DIR=$(cygpath -u "$OLLAMA_DIR"); fi
    if [[ -d "$OLLAMA_DIR" ]]; then
        add_path "$OLLAMA_DIR"
    fi
fi

# Start Ollama service if not reachable
if need_cmd ollama; then
    if ! curl -s --connect-timeout 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "  Starting Ollama service..."
        ollama serve >/dev/null 2>&1 &
        sleep 2
    fi
else
    echo "  Ollama not found; the app may need it at runtime."
fi

# ── WiX Toolset (for jpackage .exe) ─────────────────────────────────────────
echo "Checking WiX Toolset (optional)..."
if ! need_cmd candle; then
    winget install --id "WiXToolset.WiX.Toolset" -e --source winget \
        --accept-package-agreements --accept-source-agreements || true
fi

# ── Final report ────────────────────────────────────────────────────────────
echo ""
echo "===== environment summary ====="
echo "JAVA_HOME = $JAVA_HOME"
echo "java      : $(command -v java || echo 'missing')"
echo "cmake     : $(command -v cmake || echo 'missing')"
echo "ollama    : $(command -v ollama || echo 'missing')"
echo "mvn       : $(command -v mvn || echo 'use ./mvnw')"
echo ""
echo "You can now build the project:"
echo "  bash build.sh                # full build + installer"
echo "  cmake -S native -B native/build -G 'Visual Studio 17 2022'"
echo "  ./mvnw clean javafx:run"

# ── Optional: build immediately with --build flag ───────────────────────────
if [[ "${1:-}" == "--build" ]]; then
    echo ""
    echo "===== starting build ====="
    mkdir -p "$BUILD_DIR" "$STAGING_DIR"

    # Native C++ DLL
    cmake -S "$NATIVE_DIR" -B "$BUILD_DIR" -G "Visual Studio 17 2022" -A x64
    cmake --build "$BUILD_DIR" --config Release

    # Java build & staging
    if [[ -f "$MVN_CMD" ]]; then
        "$MVN_CMD" -q -DskipTests package
        "$MVN_CMD" -q -DskipTests dependency:copy-dependencies \
            -DincludeScope=runtime -DoutputDirectory="$STAGING_DIR"
    elif need_cmd mvn; then
        mvn -q -DskipTests package
        mvn -q -DskipTests dependency:copy-dependencies \
            -DincludeScope=runtime -DoutputDirectory="$STAGING_DIR"
    else
        echo "ERROR: no Maven available." >&2
        exit 1
    fi

    MAIN_JAR=$(find "$ROOT/target" -maxdepth 1 -name "*.jar" \
        ! -name "*-sources.jar" ! -name "original-*.jar" | head -n1)
    cp "$MAIN_JAR" "$STAGING_DIR/app.jar"
    cp "$BUILD_DIR/Release/gpu_memory_native.dll" "$STAGING_DIR/"

    echo "Creating Windows installer..."
    "$JAVA_HOME/bin/jpackage" \
        --type exe \
        --name "Erudition-AI" \
        --app-version 1.0.0 \
        --input "$STAGING_DIR" \
        --main-jar app.jar \
        --main-class erudition_program.MainApp \
        --dest "$DIST_DIR" \
        --win-console \
        --java-options "-Dnative.dir=\$APPDIR"

    echo ""
    echo "Build complete – output in $DIST_DIR"
fi
echo "output copied to clipboard"
read -p "press enter to close"