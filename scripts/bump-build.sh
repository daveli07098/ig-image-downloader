#!/usr/bin/env bash
# bump-build.sh — bump the version and (optionally) commit, build, install.
#
# Version format:  pubspec  →  MAJOR.MINOR.PATCH+BUILD   (e.g. 1.0.1+0)
#                  AppBar   →  vMAJOR.MINOR.PATCH.BUILD   (e.g. v1.0.1.0)
#
# BUILD is the per-release counter (the 4th display segment). It increments on
# a plain build bump and RESETS to 0 whenever PATCH/MINOR/MAJOR changes — so a
# new sub-version always starts counting from .0 again.
#
# NOTE: BUILD can reset freely because the Android versionCode is NOT taken
# from it directly — android/app/build.gradle.kts derives a strictly-increasing
# versionCode from the full semver (major*10M + minor*100k + patch*1k + BUILD).
# So resetting the display counter never causes an install "downgrade".
#
# Usage (from repo root):
#   ./scripts/bump-build.sh                 # +1 BUILD          (1.0.1+3 → 1.0.1+4)
#   ./scripts/bump-build.sh --patch         # +1 PATCH, BUILD=0 (1.0.1+4 → 1.0.2+0)
#   ./scripts/bump-build.sh --minor         # +1 MINOR, BUILD=0 (1.0.2+4 → 1.1.0+0)
#   ./scripts/bump-build.sh --major         # +1 MAJOR, BUILD=0 (1.1.0+4 → 2.0.0+0)
#   ./scripts/bump-build.sh --no-commit     # bump + stage only (fold into a code commit)
#   ./scripts/bump-build.sh --build         # bump + commit + build APK + adb install -r -d
#
# Flags combine, e.g.:  ./scripts/bump-build.sh --patch --build
set -euo pipefail
cd "$(dirname "$0")/.."

ADB=~/Library/Android/sdk/platform-tools/adb
PUBSPEC=pubspec.yaml
HOME_SCREEN=lib/screens/home_screen.dart

# ── Parse flags ───────────────────────────────────────────────────────────────
LEVEL="build"        # build | patch | minor | major
NO_COMMIT=0
DO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --major)     LEVEL="major" ;;
    --minor)     LEVEL="minor" ;;
    --patch)     LEVEL="patch" ;;
    --build)     DO_BUILD=1 ;;
    --no-commit) NO_COMMIT=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# ── Read current semver + build number ────────────────────────────────────────
FULL_VERSION=$(grep '^version:' "$PUBSPEC" | awk '{print $2}')
SEMVER="${FULL_VERSION%+*}"          # e.g. 1.0.1
BUILD="${FULL_VERSION#*+}"           # e.g. 3
IFS='.' read -r MAJOR MINOR PATCH <<< "$SEMVER"

# ── Compute next version ──────────────────────────────────────────────────────
case "$LEVEL" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0; NEXT_BUILD=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0;          NEXT_BUILD=0 ;;
  patch) PATCH=$((PATCH + 1));                   NEXT_BUILD=0 ;;
  build)                                         NEXT_BUILD=$((BUILD + 1)) ;;
esac
NEW_SEMVER="${MAJOR}.${MINOR}.${PATCH}"

NEW_PUBSPEC_VERSION="${NEW_SEMVER}+${NEXT_BUILD}"
NEW_DISPLAY_VERSION="v${NEW_SEMVER}.${NEXT_BUILD}"
OLD_DISPLAY_VERSION="v${SEMVER}.${BUILD}"

echo "Bumping  ${SEMVER}+${BUILD}  →  ${NEW_PUBSPEC_VERSION}   (${LEVEL})"
echo "Display  ${OLD_DISPLAY_VERSION}  →  ${NEW_DISPLAY_VERSION}"

# ── Update pubspec.yaml ───────────────────────────────────────────────────────
sed -i '' "s/^version: .*/version: ${NEW_PUBSPEC_VERSION}/" "$PUBSPEC"

# ── Update AppBar version string in home_screen.dart ─────────────────────────
sed -i '' "s/'${OLD_DISPLAY_VERSION}'/'${NEW_DISPLAY_VERSION}'/" "$HOME_SCREEN"

# ── Commit ────────────────────────────────────────────────────────────────────
git add "$PUBSPEC" "$HOME_SCREEN"
if [[ "$NO_COMMIT" == "1" ]]; then
  # Files are staged — caller includes them in their own code commit.
  echo "Staged version bump (${NEW_DISPLAY_VERSION}) — add these files to your commit:"
  echo "  $PUBSPEC"
  echo "  $HOME_SCREEN"
  exit 0
fi
git commit -m "chore: bump to ${NEW_DISPLAY_VERSION}"
echo "Committed: $(git rev-parse --short HEAD)"

# ── Optionally build + install on the connected device ───────────────────────
# Detect whatever real device is plugged in and build for *its* platform —
# Android phone/emulator → APK + adb install; iOS device/simulator → flutter
# install. Physical devices are preferred over emulators/simulators. Falls back
# to a plain Android APK build if no device is connected.
if [[ "$DO_BUILD" == "1" ]]; then
  # Ask Flutter what is connected (JSON), then pick the best target with python.
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

  if [[ -z "$DEVICE_ID" ]]; then
    echo "No connected device found — building a release APK only (not installing)…"
    fvm flutter build apk --release
    echo "Built ${NEW_DISPLAY_VERSION} APK → build/app/outputs/flutter-apk/app-release.apk"
  elif [[ "$PLATFORM" == "android" ]]; then
    echo "Android device '${DEVICE_ID}' detected — building release APK…"
    fvm flutter build apk --release
    echo "Installing (keeping app data, allowing versionCode downgrade)…"
    ${ADB} -s "$DEVICE_ID" install -r -d build/app/outputs/flutter-apk/app-release.apk
    echo "Installed ${NEW_DISPLAY_VERSION} on ${DEVICE_ID} (android)"
  else
    # iOS physical device or simulator: flutter install handles build + deploy
    # without staying attached (unlike `flutter run`).
    echo "iOS device '${DEVICE_ID}' detected — building + installing release…"
    fvm flutter install --release -d "$DEVICE_ID"
    echo "Installed ${NEW_DISPLAY_VERSION} on ${DEVICE_ID} (ios)"
  fi
fi
