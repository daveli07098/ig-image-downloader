#!/usr/bin/env bash
# build-install.sh — build the app and install it on the connected device.
#
# Detects whatever real device is plugged in and builds for *its* platform:
#   Android phone/emulator → release APK + `adb install -r -d`
#   iOS device/simulator   → `flutter install --release`
# Physical devices are preferred over emulators/simulators. When no device is
# connected it builds a release APK only (no install), so the call is always
# safe to run unattended.
#
# This is the single source of truth for "build + put it on my phone". It is
# called automatically by bump-build.sh after a commit, and can also be run on
# its own after a manual commit (the --no-commit + fold-into-code-commit flow).
#
# Usage:
#   ./scripts/build-install.sh            # build + install if a device is connected
#   ./scripts/build-install.sh --apk-only # build a release APK, never install
set -euo pipefail
cd "$(dirname "$0")/.."

ADB=~/Library/Android/sdk/platform-tools/adb
APK=build/app/outputs/flutter-apk/app-release.apk

APK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --apk-only) APK_ONLY=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Current display version (for nicer log lines); best-effort only.
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' || echo '?')

# ── Pick the best connected target ───────────────────────────────────────────
# Ask Flutter what is connected (JSON), then choose with python.
# Output: "<id>\t<platformType>" (platformType = android | ios), empty if none.
DEVICES_JSON=$(fvm flutter devices --machine 2>/dev/null || echo '[]')
TARGET=$(printf '%s' "$DEVICES_JSON" | python3 -c '
import json, sys
try:
    devs = json.load(sys.stdin)
except Exception:
    devs = []
# Keep only installable mobile targets that Flutter can deploy to.
cand = [d for d in devs
        if d.get("platformType") in ("android", "ios") and d.get("isSupported", True)]
# Prefer a physical device over an emulator/simulator; keep stable order otherwise.
cand.sort(key=lambda d: 0 if not d.get("emulator", False) else 1)
if cand:
    d = cand[0]
    print("{}\t{}".format(d.get("id", ""), d.get("platformType", "")))
' 2>/dev/null || true)

DEVICE_ID="${TARGET%%$'\t'*}"
PLATFORM="${TARGET##*$'\t'}"

# ── Build (+ install) ────────────────────────────────────────────────────────
if [[ "$APK_ONLY" == "1" || -z "$DEVICE_ID" ]]; then
  [[ -z "$DEVICE_ID" && "$APK_ONLY" != "1" ]] \
    && echo "No connected device found — building a release APK only (not installing)…"
  fvm flutter build apk --release
  echo "Built ${VERSION} APK → ${APK}"
  exit 0
fi

if [[ "$PLATFORM" == "android" ]]; then
  echo "Android device '${DEVICE_ID}' detected — building release APK…"
  fvm flutter build apk --release
  echo "Installing (keeping app data, allowing versionCode downgrade)…"
  ${ADB} -s "$DEVICE_ID" install -r -d "${APK}"
  echo "Installed ${VERSION} on ${DEVICE_ID} (android)"
else
  # iOS physical device or simulator: flutter install handles build + deploy
  # without staying attached (unlike `flutter run`).
  echo "iOS device '${DEVICE_ID}' detected — building + installing release…"
  fvm flutter install --release -d "$DEVICE_ID"
  echo "Installed ${VERSION} on ${DEVICE_ID} (ios)"
fi
