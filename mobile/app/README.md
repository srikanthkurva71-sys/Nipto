# Nipto Android application

This directory is the Flutter project root.

- `lib/` — application entry point, screens, services, theme and widgets.
- `test/` — Dart unit and widget tests.
- `assets/` — application-owned images and other bundled resources.
- `config/dev.json` — client-safe local Supabase URL and publishable key.
- `pubspec.yaml` — Flutter package metadata and dependencies.
- `analysis_options.yaml` — Dart analyzer and lint configuration.
- `android/` — generated native Android host project.

## Bootstrap Android

From the repository root:

```bash
flutter create --platforms=android --org com.nipto --project-name nipto mobile/app
python scripts/configure_android_manifest.py
```

Then run commands from this directory:

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=config/dev.json
```

Never put Supabase service-role keys or other backend secrets in this Flutter project.
