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

def platform_of(d):
    # Newer Flutter emits only "targetPlatform" (e.g. "android-arm64",
    # "ios", "darwin", "web-javascript"); older builds also had "platformType".
    # Normalise both to "android" / "ios" / other.
    pt = d.get("platformType")
    if pt in ("android", "ios"):
        return pt
    tp = (d.get("targetPlatform") or "")
    if tp.startswith("android"):
        return "android"
    if tp.startswith("ios"):
        return "ios"
    return ""

try:
    devs = json.load(sys.stdin)
except Exception:
    devs = []
# Keep only installable mobile targets (drop desktop/web).
cand = [(d, platform_of(d)) for d in devs if d.get("isSupported", True)]
cand = [(d, p) for (d, p) in cand if p in ("android", "ios")]
# Prefer a physical device over an emulator/simulator; keep stable order otherwise.
cand.sort(key=lambda dp: 0 if not dp[0].get("emulator", False) else 1)
if cand:
    d, p = cand[0]
    print("{}\t{}".format(d.get("id", ""), p))
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
