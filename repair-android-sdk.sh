#!/usr/bin/env bash
set -euo pipefail
echo "START: Android SDK repair helper"
SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
echo "ANDROID_SDK_ROOT = $SDK_ROOT"

echo
echo "1) Show installed platforms:"
ls -lh "$SDK_ROOT/platforms" || true
echo

PLATFORM_DIR="$SDK_ROOT/platforms/android-36"
JAR="$PLATFORM_DIR/android.jar"

echo "2) Inspect android-36/android.jar (if present):"
if [ -f "$JAR" ]; then
  echo "Found: $JAR"
  ls -lh "$JAR"
  echo "(file type)"
  file "$JAR" || true
  echo "(try listing contents - may fail if corrupted)"
  unzip -l "$JAR" | head -n 20 || true
  stat -c '%s %n' "$JAR" || true
else
  echo "No android-36 platform directory found at $PLATFORM_DIR"
fi
echo

echo "3) Stop Gradle daemons (if any)"
if [ -x "./android/gradlew" ]; then
  ./android/gradlew --stop || true
fi

# Find sdkmanager
SDKMANAGER=""
if [ -x "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  SDKMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
elif [ -x "$SDK_ROOT/tools/bin/sdkmanager" ]; then
  SDKMANAGER="$SDK_ROOT/tools/bin/sdkmanager"
elif command -v sdkmanager >/dev/null 2>&1; then
  SDKMANAGER="$(command -v sdkmanager)"
fi

if [ -z "$SDKMANAGER" ]; then
  echo "WARNING: sdkmanager not found in expected locations."
  echo "Please open Android Studio -> SDK Manager -> install 'Android SDK Command-line Tools'."
  echo "Skipping automatic reinstall; you can remove $PLATFORM_DIR manually and reinstall later."
else
  echo "Using sdkmanager: $SDKMANAGER"
  echo "Updating/ensuring cmdline-tools;latest (may request acceptance of licenses)"
  "$SDKMANAGER" --sdk_root="$SDK_ROOT" --install "cmdline-tools;latest" || true

  echo "Uninstalling platforms;android-36 (if installed)"
  "$SDKMANAGER" --sdk_root="$SDK_ROOT" --uninstall "platforms;android-36" || true

  echo "Removing folder (if present) to ensure clean install"
  rm -rf "$PLATFORM_DIR" || true

  echo "Installing platforms;android-36"
  "$SDKMANAGER" --sdk_root="$SDK_ROOT" "platforms;android-36"
fi

echo
echo "4) Clear Kotlin DSL accessors cache (targeted)"
rm -rf ~/.gradle/caches/*/kotlin-dsl/accessors || true

echo
echo "5) Rebuild Flutter app (clean, get, run)"
flutter clean || true
flutter pub get
# Try a normal run; if it fails, capture Gradle log
echo "Attempting flutter run - will capture detailed Gradle log on failure..."
if flutter run -d 58091JEBF23258; then
  echo "App launched successfully."
  exit 0
else
  echo "flutter run failed; collecting Gradle assembleDebug log..."
  mkdir -p /tmp/bakers-logs
  cd android
  ./gradlew assembleDebug --stacktrace --info > /tmp/bakers-logs/gradle-assemble-debug.log 2>&1 || true
  echo "Gradle log saved to /tmp/bakers-logs/gradle-assemble-debug.log"
  echo "Tail of log:"
  tail -n 200 /tmp/bakers-logs/gradle-assemble-debug.log || true
  exit 1
fi
