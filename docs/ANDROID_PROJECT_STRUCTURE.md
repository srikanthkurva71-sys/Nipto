# Nipto Android application structure

The Flutter application lives at `mobile/app/`. That directory is the **only app package root**. Android is the only product target. A generated web host is also used for local Chrome development previews; it is not a web product or release target.

## Repository layout

```text
Nipto/
├── .github/
│   └── workflows/
│       └── android-ci.yml
├── .vscode/
│   ├── extensions.json
│   ├── launch.json
│   ├── settings.json
│   └── tasks.json
├── docs/                         # product, architecture, security and delivery
├── mobile/
│   └── app/                      # actual Flutter Android application root
│       ├── android/              # generated Android Gradle project
│       ├── web/                  # generated local Chrome development host only
│       ├── config/
│       │   └── dev.json          # client-safe Supabase dev config
│       ├── lib/
│       │   ├── main.dart         # Flutter entry point
│       │   ├── nipto_app.dart    # root MaterialApp and app configuration
│       │   ├── screens/          # app screens and navigation destinations
│       │   ├── services/         # Supabase, session, storage and WebRTC
│       │   ├── theme/            # Nipto theme
│       │   └── widgets/          # reusable Nipto widgets
│       ├── test/                 # Dart tests
│       ├── analysis_options.yaml
│       ├── pubspec.yaml          # package manifest
│       ├── pubspec.lock          # resolved package versions (generated)
│       └── README.md
├── scripts/                      # Windows bootstrap and repository checks
└── supabase/
    ├── functions/
    └── migrations/
```

There are no iOS, macOS, Windows or Linux targets. The Android host and local Chrome preview host are generated using Flutter's `--platforms=android,web` option. The generated native project contains the Android Gradle wrapper, app module, manifest, Kotlin activity and resources. Do not commit machine-specific SDK paths, Gradle caches, `.dart_tool/` or build output.

## What belongs in each app folder

- `android/`: Android manifest, Gradle configuration, Kotlin host activity, app resources and wrapper. Android permissions and native plugin configuration belong here.
- `config/`: optional client-safe environment overrides only. Default Nipto Supabase URL and publishable key are built into the app; never put service-role keys, TURN secrets, signing keys or private credentials here.
- `lib/screens/`: user-facing screens and navigation destinations.
- `lib/services/`: data access and platform services. Enforce authorization in Supabase RLS and trusted server functions, not only in widgets.
- `lib/theme/`: colors, typography and component theme.
- `lib/widgets/`: genuinely reusable UI components.
- `test/`: unit and widget tests.
- `pubspec.yaml`: authoritative direct package declarations.

Keep the existing working folder names. Do not create empty `core/`, `features/`, `shared/`, platform folders or sample files just to make the tree look larger. If a future feature grows enough to justify a new folder, add it together with real source files, tests and updated imports.

## Direct package dependencies

| Package | Responsibility |
|---|---|
| `supabase_flutter` | Supabase Auth, PostgreSQL, Storage and Realtime |
| `image_picker` | User-selected photo and video media |
| `video_player` | Feed, status and Shorts playback |
| `flutter_webrtc` | Audio/video calling |
| `flutter_secure_storage` | Platform-backed secure storage |
| `shared_preferences` | Non-secret local PKCE metadata |
| `http` | Cross-platform calls to Nipto identity Edge Functions |

Flutter SDK libraries are built in. `flutter_test` and `flutter_lints` are development dependencies. Every package imported by app code must be declared directly in `pubspec.yaml`; do not rely on transitive dependencies. Add a package only when implemented code needs it.

After changing dependencies, run `flutter pub get` and commit `pubspec.lock`.

## Windows prerequisites

- Flutter stable (includes Dart)
- 64-bit Java 17
- Android SDK Platform 36
- Android SDK Platform-Tools
- Android SDK Build-Tools 36.0.0
- Android SDK Command-line Tools (latest)
- Python 3 (used by the manifest setup utility)
- VS Code with the Dart and Flutter extensions

## Create and validate the Android app

From PowerShell at the repository root:

```powershell
.\\scripts\\bootstrap_nipto_windows.ps1
```

The script checks Flutter and Java, creates the Android host and local Chrome preview host under `mobile/app`, applies the Nipto OAuth callback, sets Android minimum SDK to API 24, resolves declared packages, formats Dart, runs static analysis and executes tests.

After bootstrap, launch on an attached Android phone or emulator:

```powershell
Set-Location mobile/app
flutter devices
flutter run
```

Run the development UI preview in Chrome (not a supported release target):\n\n```powershell\nflutter run -d chrome\n```\n\nBuild an APK with the project's default Supabase configuration:

```powershell
flutter build apk
```

The output is under `mobile/app/build/app/outputs/flutter-apk/app-debug.apk`.

## VS Code

Open the repository root, not just `mobile/app`. Install the recommended Dart and Flutter extensions. Select **Nipto (Android)** in Run and Debug and press F5. The checked-in tasks provide package resolution, analysis, tests and debug APK build commands.

## Physical Android testing

1. Enable Developer options and USB debugging on a test device.
2. Connect it and verify it appears in `flutter devices`.
3. Run Nipto from VS Code or `flutter run`.
4. Grant camera/microphone permissions only when starting a call.
5. Test sign-in, session restoration, chat, media upload, notifications, call interruptions and reconnects.
6. Use test accounts and non-production data.

A GitHub commit does not automatically update a developer's Windows folder. Pull the branch and run the bootstrap script locally to create the Android native project. CI also generates the Android host from this same checked-in Flutter package.
