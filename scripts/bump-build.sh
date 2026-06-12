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
# NOTE: BUILD is also the Android versionCode. Resetting it means a new
# sub-version installs as a versionCode "downgrade", so sideload installs use
# `adb install -r -d` (the -d below allows it). This is fine for local/dev
# distribution but would need a monotonic versionCode for the Play Store.
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

# ── Optionally build + install ────────────────────────────────────────────────
if [[ "$DO_BUILD" == "1" ]]; then
  echo "Building release APK…"
  fvm flutter build apk --release
  echo "Installing on device (keeping app data, allowing versionCode downgrade)…"
  DEVICE=$(${ADB} devices | awk 'NR==2{print $1}')
  ${ADB} -s "$DEVICE" install -r -d build/app/outputs/flutter-apk/app-release.apk
  echo "Installed ${NEW_DISPLAY_VERSION} on ${DEVICE}"
fi
