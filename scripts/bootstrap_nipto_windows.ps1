[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $RepositoryRoot "mobile/app"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Write-Host ""
    Write-Host ("> " + $Command + " " + ($Arguments -join " ")) -ForegroundColor Cyan
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed with exit code " + $LASTEXITCODE + ": " + $Command)
    }
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not on PATH. Install Flutter stable and add its bin directory to PATH."
}
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "Java is not on PATH. Install a 64-bit JDK 17 and configure JAVA_HOME."
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python 3 is required for the Android manifest setup script."
}

# java -version writes its version banner to stderr. Capture it through cmd.exe
# so PowerShell's Stop preference does not treat the banner as a terminating error.
$javaVersion = (& cmd.exe /d /c "java -version 2>&1" | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to execute Java. Verify JAVA_HOME and PATH."
}
if ($javaVersion -notmatch 'version "17\.') {
    Write-Warning ("Nipto's documented Android toolchain uses Java 17. Detected Java output: " + $javaVersion)
}

Invoke-Checked "flutter" @("--version")
Write-Host ""
Write-Host "> flutter doctor --verbose" -ForegroundColor Cyan
flutter doctor --verbose

# Generate only the native Android host. Dart source and pubspec.yaml remain the
# checked-in source of truth; Flutter resolves dependencies from pubspec.yaml.
Invoke-Checked "flutter" @(
    "create",
    "--platforms=android,web",
    "--org", "com.nipto",
    "--project-name", "nipto",
    $AppRoot
)

Invoke-Checked "python" @(
    (Join-Path $RepositoryRoot "scripts/configure_android_manifest.py")
)

$GradleFile = Join-Path $AppRoot "android/app/build.gradle.kts"
if (-not (Test-Path $GradleFile)) {
    throw ("Generated Android Gradle Kotlin file not found: " + $GradleFile)
}
$gradleText = Get-Content $GradleFile -Raw
if ($gradleText -match 'minSdk\s*=\s*flutter\.minSdkVersion') {
    $gradleText = $gradleText -replace 'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24'
    [System.IO.File]::WriteAllText($GradleFile, $gradleText, [System.Text.UTF8Encoding]::new($false))
} elseif ($gradleText -notmatch 'minSdk\s*=\s*24') {
    throw ("Could not safely set minSdk to API 24 in " + $GradleFile)
}

Push-Location $AppRoot
try {
    Invoke-Checked "flutter" @("pub", "get")
    Invoke-Checked "dart" @("format", "lib", "test")
    Invoke-Checked "flutter" @("analyze")
    if (-not $SkipTests) {
        Invoke-Checked "flutter" @("test")
    }
    Write-Host ""
    Write-Host "Nipto setup completed. Run 'flutter run' for the default device, 'flutter run -d chrome' for the web development preview, or 'flutter build apk' for Android." -ForegroundColor Green
} finally {
    Pop-Location
}
