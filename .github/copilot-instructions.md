<!-- Copilot / AI Agent Instructions for Bakers-Timer (Flutter app) -->

# Purpose
Provide concise, actionable guidance that lets an AI agent be productive in this Flutter repository (cross-platform mobile + desktop + web). Do not scaffold unrelated stacks — this is a Flutter app.

## Quick repo facts
- Primary entry: [lib/main.dart](lib/main.dart)
- Pub manifest: [pubspec.yaml](pubspec.yaml)
- Tests: [test/widget_test.dart](test/widget_test.dart)
- Platform folders: `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` (native runners/CMake present)
- Linting: `analysis_options.yaml` at repo root
- Helper script: `repair-android-sdk.sh` (useful for Android SDK setup on non-standard dev environments)

## Immediate steps for an AI agent
- Confirm repo state: run `git status` and inspect `pubspec.yaml` and `lib/main.dart` to identify SDK constraints and package usage.
- Do not re-scaffold as a different stack. This repo is a Flutter app — changes should preserve Flutter structure.
- When proposing large changes, open a draft PR and include simple manual verification steps (build/run commands below).

## Build / run / test commands (practical examples)
- Install deps: `flutter pub get`
- Run on attached device/emulator: `flutter run`
- Run on specific targets: `flutter run -d windows`, `-d linux`, `-d ios` (macOS required), `-d chrome` for web
- Build release: `flutter build apk` / `flutter build ios` / `flutter build windows`
- Run tests: `flutter test`
- Format: `dart format .`

## Project-specific patterns and notes
- Single Flutter app supporting mobile + desktop + web — do not assume only mobile. Desktop targets include `CMakeLists.txt` and platform runner code (see `linux/`, `windows/`, `macos/`).
- Plugins are registered using generated plugin registrant files under each platform (`*/generated_plugin_registrant.*`). Avoid manual edits to generated registrant files.
- Assets are declared in `pubspec.yaml` and live in `assets/` — when adding assets update `pubspec.yaml` accordingly.
- Tests are present under `test/` — follow existing test structure when adding new tests.
- Avoid changing platform runner files unless fixing platform-specific issues; discuss breaking changes in a draft PR.

## Troubleshooting & environment hints
- Android setup: the repo includes `repair-android-sdk.sh` — check it if contributors report Android SDK path issues (Windows users may need WSL or Android Studio).
- Desktop builds require native toolchains: CMake for Linux/Windows/macOS; macOS builds require Xcode.

## When changing code
- Small, focused commits. Each visual or platform change should include at least one local verification step (e.g., `flutter run -d linux` or `flutter test`).
- Preserve public behaviors of `lib/` unless a breaking change is explicitly requested.

## Files to inspect for context when working
- `pubspec.yaml` — dependency versions and SDK constraints
- `lib/main.dart` — app entry and high-level routing
- `assets/` — images and static resources
- `test/widget_test.dart` — example of test structure
- `android/` and `ios/` runner folders — native integration points

## Safety and review
- Never commit credentials or keystore files. If secrets are detected, redact and open an issue.
- For platform-specific or CI changes, propose a draft PR and list exact local commands to reproduce.

## Ask the maintainer
- Confirm target Flutter SDK range (check `pubspec.yaml`) before bumping dependencies.
- If adding CI, ask which platforms to build (mobile only vs desktop + web).

End of instructions.
