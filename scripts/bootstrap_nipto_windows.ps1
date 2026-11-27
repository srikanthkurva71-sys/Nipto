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

$AndroidSdk = $env:ANDROID_HOME
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $AndroidSdk = $env:ANDROID_SDK_ROOT
}
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    throw "ANDROID_HOME or ANDROID_SDK_ROOT must point to the installed Android SDK."
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
    (Join-Path $RepositoryRoot "scripts/configure_android_platform.py")
)

$NdkRoot = Join-Path $AndroidSdk "ndk\28.2.13676358"
if (-not (Test-Path (Join-Path $NdkRoot "ndk-build.cmd"))) {
    $SdkManager = Join-Path $AndroidSdk "cmdline-tools\latest\bin\sdkmanager.bat"
    if (-not (Test-Path $SdkManager)) {
        throw ("Android sdkmanager not found at " + $SdkManager)
    }
    Write-Host ""
    Write-Host "> $SdkManager --licenses" -ForegroundColor Cyan
    1..30 | ForEach-Object { "y" } | & $SdkManager --licenses | Out-Null
    Invoke-Checked $SdkManager @("--install", "ndk;28.2.13676358")
}

Push-Location $AppRoot
try {
    Invoke-Checked "flutter" @("pub", "get")
    Invoke-Checked "dart" @("run", "flutter_launcher_icons")
    Invoke-Checked "dart" @("run", "flutter_native_splash:create")
    Invoke-Checked "dart" @("format", "lib", "test")
    Invoke-Checked "flutter" @("analyze", "--no-fatal-infos")
    if (-not $SkipTests) {
        Invoke-Checked "flutter" @("test")
    }
    Write-Host ""
    Write-Host "Nipto setup completed. Run 'flutter run' for the default device, 'flutter run -d chrome' for the web development preview, or 'flutter build apk --debug' for Android." -ForegroundColor Green
} finally {
    Pop-Location
}
