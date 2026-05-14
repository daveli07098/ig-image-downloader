#!/usr/bin/env bash
# bump-build.sh — increment the build counter, update display version, commit.
#
# Version format:  pubspec  →  1.0.0+N
#                  AppBar   →  v1.0.0.N
#
# Usage (from repo root):
#   ./scripts/bump-build.sh               # bump + commit (standalone)
#   ./scripts/bump-build.sh --no-commit   # bump + stage only (fold into a code commit)
#   ./scripts/bump-build.sh --build       # bump + commit + build APK + adb install -r
#
set -euo pipefail
cd "$(dirname "$0")/.."

ADB=~/Library/Android/sdk/platform-tools/adb
PUBSPEC=pubspec.yaml
HOME_SCREEN=lib/screens/home_screen.dart

# ── Read current semver and build number ─────────────────────────────────────
FULL_VERSION=$(grep '^version:' "$PUBSPEC" | awk '{print $2}')
SEMVER="${FULL_VERSION%+*}"          # e.g. 1.0.0
BUILD="${FULL_VERSION#*+}"           # e.g. 1
NEXT_BUILD=$((BUILD + 1))

NEW_PUBSPEC_VERSION="${SEMVER}+${NEXT_BUILD}"
NEW_DISPLAY_VERSION="v${SEMVER}.${NEXT_BUILD}"
OLD_DISPLAY_VERSION="v${SEMVER}.${BUILD}"

echo "Bumping  ${SEMVER}+${BUILD}  →  ${NEW_PUBSPEC_VERSION}"
echo "Display  ${OLD_DISPLAY_VERSION}  →  ${NEW_DISPLAY_VERSION}"

# ── Update pubspec.yaml ───────────────────────────────────────────────────────
sed -i '' "s/^version: .*/version: ${NEW_PUBSPEC_VERSION}/" "$PUBSPEC"

# ── Update AppBar version string in home_screen.dart ─────────────────────────
sed -i '' "s/'${OLD_DISPLAY_VERSION}'/'${NEW_DISPLAY_VERSION}'/" "$HOME_SCREEN"

# ── Commit ────────────────────────────────────────────────────────────────────
git add "$PUBSPEC" "$HOME_SCREEN"
if [[ "${1:-}" == "--no-commit" ]]; then
  # Files are staged — caller includes them in their own code commit.
  echo "Staged version bump (${NEW_DISPLAY_VERSION}) — add these files to your commit:"
  echo "  $PUBSPEC"
  echo "  $HOME_SCREEN"
  exit 0
fi
git commit -m "chore: bump to ${NEW_DISPLAY_VERSION}"
echo "Committed: $(git rev-parse --short HEAD)"
# ── Optionally build + install ────────────────────────────────────────────────
if [[ "${1:-}" == "--build" ]]; then
  echo "Building release APK…"
  fvm flutter build apk --release
  echo "Installing on device (keeping app data)…"
  DEVICE=$(${ADB} devices | awk 'NR==2{print $1}')
  ${ADB} -s "$DEVICE" install -r -d build/app/outputs/flutter-apk/app-release.apk
  echo "Installed ${NEW_DISPLAY_VERSION} on ${DEVICE}"
fi
