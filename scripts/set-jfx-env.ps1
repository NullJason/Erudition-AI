
$ErrorActionPreference = "Stop"

$pomPath = "$PSScriptRoot\..\pom.xml"

[xml]$pom = Get-Content $pomPath
$ns = @{ mvn = "http://maven.apache.org/POM/4.0.0" }
$versionNode = Select-Xml -Xml $pom -XPath "//mvn:javafx.version" -Namespace $ns
if (-not $versionNode) {
    Write-Error "javafx.version not found in pom.xml"
    exit 1
}
$fxVersion = $versionNode.Node.InnerText.Trim()

$repo = "$env:USERPROFILE\.m2\repository"

$controls = "$repo\org\openjfx\javafx-controls\$fxVersion\javafx-controls-$fxVersion.jar"
$graphics = "$repo\org\openjfx\javafx-graphics\$fxVersion\javafx-graphics-$fxVersion-win.jar"
$base     = "$repo\org\openjfx\javafx-base\$fxVersion\javafx-base-$fxVersion.jar"

$modulePath = "$controls;$graphics;$base"

$envFile = "$PSScriptRoot\..\.jfx.env"
@"
JAVA_HOME=$env:JAVA_HOME
JFX_MODULE_PATH=$modulePath
"@ | Out-File -Encoding ascii -FilePath $envFile

Write-Output "JavaFX $fxVersion module path written to .jfx.env"