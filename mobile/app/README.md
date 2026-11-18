# Nipto Android app

This is the Flutter package root for the **Android-only Nipto application**. Open the repository root in VS Code.

## Real app folders

- `android/` — generated Android Gradle project, manifest, Kotlin host, resources and wrapper.
- `lib/main.dart` — Flutter entry point.
- `lib/nipto_app.dart` — root application widget and theme setup.
- `lib/screens/` — authentication, home, chats, conversations, profile, status, Shorts, calls and settings screens.
- `lib/services/` — Supabase session, secure storage, call and validation services.
- `lib/theme/` — Nipto theme.
- `lib/widgets/` — reusable Nipto widgets.
- `test/` — unit and widget tests.
- `config/dev.json` — client-safe Supabase URL and publishable key.
- `pubspec.yaml` — direct package dependencies.
- `pubspec.lock` — exact resolved versions after `flutter pub get`.
- `analysis_options.yaml` — Dart analyzer rules.

No iOS, macOS, Windows, Linux or web targets are included. Keep the structure useful: do not add empty folders or placeholder feature modules.

## Windows setup

From the repository root:

```powershell
.\\scripts\\bootstrap_nipto_windows.ps1
```

This creates only the Android native host, configures the OAuth deep link and Android API 24 minimum, resolves the packages declared in `pubspec.yaml`, formats code, analyzes the project and runs tests.

## Run on Android

Open the repository root in VS Code, connect an Android phone or start an emulator, then select **Nipto (Android)** in Run and Debug and press F5.

Or use PowerShell:

```powershell
Set-Location mobile/app
flutter run --dart-define-from-file=config/dev.json
```

## Dependencies and secrets

Use only direct packages declared in `pubspec.yaml`. Add a dependency only when implemented source imports it. Never put Supabase service-role keys, TURN credentials, private signing keys or backend secrets in this app. Client authorization must be enforced by RLS and trusted backend functions.
