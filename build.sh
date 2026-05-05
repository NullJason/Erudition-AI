#!/usr/bin/env bash
set -euo pipefail

# Path setup
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$ROOT/native"
NATIVE_BUILD="$NATIVE_DIR/build"
DIST="$ROOT/dist"
STAGING="$DIST/staging"

# Dependency IDs
CMAKE_IDS=("Kitware.CMake")
JDK_IDS=("Microsoft.OpenJDK.25" "Microsoft.OpenJDK.21")
VSBT_ID="Microsoft.VisualStudio.2022.BuildTools"
WIX_IDS=("WiXToolset.WiX.Toolset" "WiXToolset.WixToolset")

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Robust installer with array support
install_any() {
    local label="$1"
    shift
    local ids=("$@")
    for id in "${ids[@]}"; do
        if winget install --id "$id" -e --source winget \
            --accept-package-agreements --accept-source-agreements >/dev/null 2>&1; then
            echo "$label installed: $id"
            return 0
        fi
    done
    return 1
}

# Path discovery logic
find_java_exe() {
    powershell.exe -NoProfile -Command '
        $candidates = @(
            (Join-Path $env:ProgramFiles "Microsoft\jdk-25\bin\java.exe"),
            (Join-Path $env:ProgramFiles "Microsoft\jdk-21\bin\java.exe")
        )
        foreach ($p in $candidates) { if (Test-Path $p) { Write-Output $p; exit 0 } }
        exit 1
    ' | tr -d '\r'
}

find_cmake_exe() {
    powershell.exe -NoProfile -Command '
        $p = Join-Path $env:ProgramFiles "CMake\bin\cmake.exe"
        if (Test-Path $p) { Write-Output $p; exit 0 }
        exit 1
    ' | tr -d '\r'
}

mkdir -p "$NATIVE_BUILD" "$DIST" "$STAGING"

# 1. Environment Bootstrap
if ! need_cmd winget; then
    echo "winget required." >&2; exit 1
fi

install_any "CMake" "${CMAKE_IDS[@]}"
install_any "OpenJDK" "${JDK_IDS[@]}"
# VS Build Tools requires specific workloads for C++ DLL compilation
winget install --id "$VSBT_ID" -e --source winget \
    --accept-package-agreements --accept-source-agreements \
    --override '--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait' || true
install_any "WiX" "${WIX_IDS[@]}" || true

# Ollama installation (optional/non-blocking)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://ollama.com/install.ps1 | iex" || true

# 2. Variable Resolution
JAVA_EXE="$(find_java_exe)"
CMAKE_EXE="$(find_cmake_exe)"
export JAVA_HOME="$(cd "$(dirname "$(dirname "$JAVA_EXE")")" && pwd)"
export PATH="$JAVA_HOME/bin:$PATH"

# 3. Native Compilation
echo "Building native components..."
"$CMAKE_EXE" -S "$NATIVE_DIR" -B "$NATIVE_BUILD" -G "Visual Studio 17 2022" -A x64
"$CMAKE_EXE" --build "$NATIVE_BUILD" --config Release

# 4. Java Build & Dependency Staging
echo "Building Java application..."
"$ROOT/mvnw" -q -DskipTests package
# Essential: Copy runtime dependencies for jpackage input directory
"$ROOT/mvnw" -q -DskipTests dependency:copy-dependencies -DincludeScope=runtime -DoutputDirectory="$STAGING"

MAIN_JAR="$(find "$ROOT/target" -maxdepth 1 -type f -name "*.jar" ! -name "*-sources.jar" ! -name "original-*.jar" | head -n 1)"
cp "$MAIN_JAR" "$STAGING/app.jar"
cp "$NATIVE_BUILD/Release/gpu_memory_native.dll" "$STAGING/"

# 5. Installer Packaging
echo "Creating Windows Installer..."
"$JAVA_HOME/bin/jpackage" \
    --type exe \
    --name "Erudition-AI" \
    --app-version 1.0.0 \
    --input "$STAGING" \
    --main-jar app.jar \
    --main-class MainApp \
    --dest "$DIST" \
    --win-console \
    --java-options "-Dnative.dir=\$APPDIR"

echo "Success: $DIST"