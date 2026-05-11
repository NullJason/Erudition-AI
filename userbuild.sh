#!/usr/bin/env bash
set -euo pipefail

# ======================================================================
# userbuild.sh – All-in-one build script for Erudition-AI
# installs missing tools, then builds the app
# ======================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$ROOT/native"
BUILD_DIR="$NATIVE_DIR/build"
DIST_DIR="$ROOT/dist"
STAGING_DIR="$DIST_DIR/staging"

# ── helper functions ────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Add directory to current PATH and user permanent PATH (Windows only)
add_path() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
    if need_cmd setx; then
        powershell.exe -NoProfile -Command "
            \$current = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (\$current -split ';' -notcontains '$dir') {
                \$new = '$dir;' + \$current
                [Environment]::SetEnvironmentVariable('Path', \$new, 'User')
            }
        " >/dev/null 2>&1 || true
    fi
}

# Install a winget package (admin required)
winget_install() {
    local label="$1"; shift
    local ids=("$@")
    # Check admin
    if ! net session >/dev/null 2>&1; then
        echo "ERROR: Administrator privileges are needed to install $label."
        echo "Please re-run this script from an elevated terminal (right-click -> Run as administrator)."
        exit 1
    fi
    for id in "${ids[@]}"; do
        echo "   Trying: winget install --id $id ..."
        if winget install --id "$id" -e --source winget \
            --accept-package-agreements --accept-source-agreements; then
            echo "[OK] Installed $label ($id)"
            return 0
        fi
    done
    echo "[ERROR] Failed to install $label." >&2
    exit 1
}

# Locate JDK 21+ via PowerShell
find_java_home() {
    powershell.exe -NoProfile -Command '
        $candidates = @(
            (Join-Path $env:ProgramFiles "Microsoft\jdk-21*"),
            (Join-Path $env:ProgramFiles "Microsoft\jdk-2[2-9]*"),
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\jdk-21*"),
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft\jdk-2[2-9]*"),
            (Join-Path $env:ProgramFiles "Java\jdk-21*"),
            (Join-Path $env:ProgramFiles "Java\jdk-2[2-9]*")
        )
        foreach ($p in $candidates) {
            $found = Get-Item $p -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { Write-Output $found.FullName; exit 0 }
        }
        exit 1
    ' | tr -d '\r'
}

# Convert Windows path to Unix form (if cygpath exists)
to_unix() {
    if need_cmd cygpath; then
        cygpath -u "$1"
    else
        echo "$1"
    fi
}

# ── winget prerequisite ─────────────────────────────────────────────────────
if ! need_cmd winget; then
    echo "Installing winget/App Installer…"
    powershell.exe -NoProfile -Command \
        "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" || {
        echo "Cannot install winget automatically. Please install the App Installer from the Microsoft Store." >&2
        exit 1
    }
fi

# ── 1. Ensure Java 21+ ──────────────────────────────────────────────────────
echo "Checking Java JDK 21+..."
if need_cmd java; then
    echo "  java found at $(command -v java)"
else
    echo "  Installing OpenJDK 21..."
    winget_install "OpenJDK 21" "Microsoft.OpenJDK.21"
fi

# Set JAVA_HOME
if [[ -z "${JAVA_HOME:-}" ]]; then
    JAVA_HOME=$(find_java_home)
fi
if [[ -z "$JAVA_HOME" || ! -f "$JAVA_HOME/bin/java.exe" ]]; then
    echo "FATAL: JDK not found after install attempt." >&2
    exit 1
fi
export JAVA_HOME
add_path "$JAVA_HOME/bin"
echo "  JAVA_HOME = $JAVA_HOME"

# ── 2. Ensure CMake ─────────────────────────────────────────────────────────
echo "Checking CMake..."
if ! need_cmd cmake; then
    winget_install "CMake" "Kitware.CMake"
    CMAKE_DIR="$(powershell.exe -NoProfile -Command 'Join-Path $env:ProgramFiles "CMake\bin"' | tr -d '\r')"
    CMAKE_DIR=$(to_unix "$CMAKE_DIR")
    add_path "$CMAKE_DIR"
fi
if need_cmd cmake; then
    echo "  cmake found at $(command -v cmake)"
else
    echo "FATAL: cmake still not found." >&2
    exit 1
fi

# ── 3. Ensure Visual Studio Build Tools (C++ compiler) ──────────────────────
echo "Checking Visual Studio Build Tools..."
VSWWHERE="$(powershell.exe -NoProfile -Command 'Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"' | tr -d '\r')"
if [[ -f "$VSWWHERE" ]]; then
    VS_PATH="$("$VSWWHERE" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>/dev/null || true)"
fi
if [[ -z "${VS_PATH:-}" ]]; then
    echo "  Installing Visual Studio 2022 Build Tools with C++ (this may take a while)..."
    winget install --id "Microsoft.VisualStudio.2022.BuildTools" -e --source winget \
        --accept-package-agreements --accept-source-agreements \
        --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait"
    # Re-check
    if [[ -f "$VSWWHERE" ]]; then
        VS_PATH="$("$VSWWHERE" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>/dev/null || true)"
    fi
fi
if [[ -n "${VS_PATH:-}" ]]; then
    echo "  Visual Studio at: $VS_PATH"
else
    echo "  WARNING: Build Tools may still be missing. The native DLL may not compile."
fi

# ── 4. Maven wrapper ───────────────────────────────────────────────────────
echo "Checking Maven wrapper..."
MVN_CMD="$ROOT/mvnw"
if [[ ! -f "$MVN_CMD" ]]; then
    echo "  Maven wrapper missing – downloading..."
    mkdir -p "$ROOT/.mvn/wrapper"
    # Download the Maven wrapper jar
    if need_cmd curl; then
        curl -sL "https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar" -o "$ROOT/.mvn/wrapper/maven-wrapper.jar"
    elif need_cmd wget; then
        wget -q "https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar" -O "$ROOT/.mvn/wrapper/maven-wrapper.jar"
    else
        echo "ERROR: Cannot download Maven wrapper (no curl/wget)." >&2
        exit 1
    fi
    # Create wrapper properties
    cat > "$ROOT/.mvn/wrapper/maven-wrapper.properties" <<EOF
distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.6/apache-maven-3.9.6-bin.zip
wrapperUrl=https://repo.maven.apache.org/maven2/org/apache/maven/wrapper/maven-wrapper/3.3.2/maven-wrapper-3.3.2.jar
EOF
    # Create a minimal mvnw script (for bash)
    cat > "$MVN_CMD" <<'SCRIPT'
#!/bin/sh
# Maven wrapper for Unix-like environments
MAVEN_HOME="$HOME/.m2/wrapper/dists/apache-maven-3.9.6-bin/1uk9md6f3f5pafg4js7u5j6n7p"
exec "$MAVEN_HOME/bin/mvn" "$@"
SCRIPT
    chmod +x "$MVN_CMD"
    echo "  Maven wrapper created."
else
    echo "  Maven wrapper present."
fi

# ── 5. Build the project ────────────────────────────────────────────────────
echo ""
echo "===== Building Erudition-AI ====="
mkdir -p "$BUILD_DIR" "$STAGING_DIR"

# 5a. Native C++ DLL
echo "Compiling native GPU memory DLL..."
cmake -S "$NATIVE_DIR" -B "$BUILD_DIR" -G "Visual Studio 17 2022" -A x64
cmake --build "$BUILD_DIR" --config Release
cp "$BUILD_DIR/Release/gpu_memory_native.dll" "$STAGING_DIR/"

# 5b. Java application (using the wrapper)
echo "Building Java application..."
"$MVN_CMD" -q -DskipTests package
"$MVN_CMD" -q -DskipTests dependency:copy-dependencies \
    -DincludeScope=runtime -DoutputDirectory="$STAGING_DIR"

# Find the main JAR
MAIN_JAR=$(find "$ROOT/target" -maxdepth 1 -name "*.jar" ! -name "*-sources.jar" ! -name "original-*.jar" | head -n1)
cp "$MAIN_JAR" "$STAGING_DIR/app.jar"

# 6. Package into a Windows installer, jpackage
echo "Creating Windows installer..."

# Collect JavaFX platform JARs (e.g., javafx-controls-21.0.7-win.jar)
FX_JARS=$(find "$STAGING_DIR" -maxdepth 1 -name "javafx-*-win*.jar" | tr '\n' ';')
FX_JARS="${FX_JARS%;}"  # remove trailing semicolon

if [[ -z "$FX_JARS" ]]; then
    echo "ERROR: No JavaFX platform JARs found in staging. Aborting." >&2
    exit 1
fi

"$JAVA_HOME/bin/jpackage" \
    --type exe \
    --name "Erudition-AI" \
    --app-version 1.0.0 \
    --input "$STAGING_DIR" \
    --main-jar app.jar \
    --main-class erudition_program.MainApp \
    --dest "$DIST_DIR" \
    --win-console \
    --module-path "$FX_JARS" \
    --add-modules javafx.controls \
    --java-options "-Dnative.dir=\$APPDIR"

echo ""
echo "===== Build complete ====="
echo "Installer: $DIST_DIR/Erudition-AI-1.0.0.exe"
echo ""
echo "You can now run the installer to install Erudition-AI on your computer."