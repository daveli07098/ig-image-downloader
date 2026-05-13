# Build Guide

## Version numbering

Format: `v{major}.{minor}.{patch}.{build}` — e.g. `v1.0.0.3`

| File | Field | Example |
|---|---|---|
| `pubspec.yaml` | `version:` | `1.0.0+3` |
| `lib/screens/home_screen.dart` | AppBar subtitle string | `'v1.0.0.3'` |

The build number (the `+N` in pubspec and the last `.N` in the display string)
increments by 1 for every release build. **Never edit these by hand** — use the
bump script instead.

### Bump before every build

```bash
# Bump version, commit, build APK, and install on device (keeps login data):
./scripts/bump-build.sh --build

# Or just bump + commit (build manually after):
./scripts/bump-build.sh
```

The script:
1. Reads `pubspec.yaml` for the current semver + build number
2. Increments the build number
3. Updates both `pubspec.yaml` and the AppBar string in `home_screen.dart`
4. Makes a `chore: bump to vX.Y.Z.N` commit
5. With `--build`: runs `fvm flutter build apk --release` then `adb install -r`

---

## Prerequisites

- **FVM 4.0.0** installed (`~/.nix-profile/bin/fvm`)
- Flutter SDK pinned to `stable` via `.fvmrc`

```bash
fvm install stable
fvm use stable
fvm flutter pub get
```

---

## Android

### Debug (USB device or emulator)

```bash
fvm flutter devices                        # list connected devices
fvm flutter run -d <device-id>
```

> Share intent only works on a real device or emulator with Instagram installed.

### Release APK (sideload)

```bash
fvm flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

#### Installing without wiping app data

`fvm flutter install` uninstalls the old APK first, which wipes app data
(session cookies, preferences). To replace the APK while keeping all data
intact — useful when you want to stay logged in across rebuilds — use
`adb install -r` directly:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

> `-r` = replace existing app. The package name and signing cert must match
> the installed version, which they always will during local development.

### Release AAB (Play Store)

```bash
fvm flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

---

## iOS

> Requires macOS + Xcode. The share extension requires a **one-time manual Xcode setup** before the first build.

### One-time: Share Extension setup

1. Open `ios/Runner.xcworkspace` in Xcode.
2. **File → New → Target → Share Extension** — name it `Share Extension`.
3. **Signing & Capabilities** → Add **App Groups** to **both** Runner and Share Extension targets.
4. Add the `CUSTOM_GROUP_ID` build setting to both targets (e.g. `group.com.yourname.igdownloader`).
5. Replace `ios/Share Extension/ShareViewController.swift` with:

   ```swift
   import receive_sharing_intent

   class ShareViewController: RSIShareViewController {}
   ```

6. In `ios/Podfile`, inside the `target 'Runner'` block, add:

   ```ruby
   target 'Share Extension' do
     inherit! :search_paths
   end
   ```

7. Run CocoaPods:

   ```bash
   cd ios && pod install && cd ..
   ```

### Debug (Simulator)

```bash
fvm flutter emulators                      # list available simulators
fvm flutter emulators --launch <id>        # start simulator
fvm flutter run -d iPhone
```

### Release IPA

```bash
fvm flutter build ipa --release
# Output: build/ios/ipa/ig_downloader.ipa
```

---

## Verify

```bash
fvm flutter analyze lib    # must show 0 errors
fvm flutter devices        # list connected devices/simulators
```

---

## Known Limitations

- **Public posts only** — private accounts and Stories behind authentication return an error.
- **Gallery permission** — on first launch, the app requests photo library access. Deny = download saves to local folder only (gallery save skipped).
- **Android API ≤ 28** — needs `WRITE_EXTERNAL_STORAGE` permission (already declared in `AndroidManifest.xml`).
- **iOS share extension** — without the Xcode App Groups setup above, sharing from Instagram will not route URLs to the app.
