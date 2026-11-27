# Nipto Android app

This is the Flutter package root for Nipto. Android is the only product target; a generated web host is retained only for local Chrome development previews. Open the repository root in VS Code.

## Real app folders

- `android/` — generated Android Gradle project, manifest, Kotlin host, resources and wrapper.
- `web/` — generated development-only Chrome host; Nipto v1 is not shipped as a web product.
- `lib/main.dart` — Flutter entry point.
- `lib/nipto_app.dart` — root application widget and theme setup.
- `lib/screens/` — authentication, home, chats, conversations, profile, status, Shorts, calls and settings screens.
- `lib/services/` — Supabase session, secure storage, call and validation services.
- `lib/theme/` — Nipto theme.
- `lib/widgets/` — reusable Nipto widgets, including the official logo mark.
- `assets/branding/` — the supplied Nipto logo PNG used by in-app branding.
- `flutter_launcher_icons.yaml` / `flutter_native_splash.yaml` — generation configs for Android launcher and splash artwork.
- `test/` — unit and widget tests.
- Supabase URL and publishable key — safe client defaults are built into `lib/main.dart`; optional Dart defines can override them for another environment.
- `pubspec.yaml` — direct package dependencies.
- `pubspec.lock` — exact resolved versions after `flutter pub get`.
- `analysis_options.yaml` — Dart analyzer rules.

No iOS, macOS, Windows or Linux targets are included. The web host is for local development only. Keep the structure useful: do not add empty folders or placeholder feature modules.

## Windows setup

From the repository root:

```powershell
.\\scripts\\bootstrap_nipto_windows.ps1
```

This creates the Android native host and a development-only web host, configures the OAuth deep link and Android API 24 minimum, resolves dependencies, formats code, analyzes the project and runs tests.

## Run on Android

Open the repository root in VS Code, connect an Android phone or start an emulator, then select **Nipto (Android)** in Run and Debug and press F5.

Or use PowerShell:

```powershell
Set-Location mobile/app
flutter run
```

## Chrome development preview

The generated web host allows a UI/API development preview with `flutter run -d chrome`. Some native capabilities, especially platform media and calling behavior, must still be validated on Android. Chrome is not a supported release target.

## Dependencies and secrets

Use only direct packages declared in `pubspec.yaml`. Add a dependency only when implemented source imports it. Never put Supabase service-role keys, TURN credentials, private signing keys or backend secrets in this app. Client authorization must be enforced by RLS and trusted backend functions.
