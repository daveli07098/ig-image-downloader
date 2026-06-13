import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load the release signing credentials from android/key.properties (gitignored).
// Absent on machines/CI without the keystore — the release build falls back to
// the debug key there so `flutter run --release` still works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.daveli.igdownloader.ig_downloader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.daveli.igdownloader.ig_downloader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionName = flutter.versionName

        // The pubspec build counter (the "+N" / 4th display segment) resets to 0
        // on each minor/sub-version bump, so it can't be used as the Android
        // versionCode directly — installs would be rejected as downgrades. Derive
        // a strictly-increasing versionCode from the full semver instead:
        //   major*10_000_000 + minor*100_000 + patch*1_000 + buildCounter
        // e.g. 1.0.1+0 -> 10_001_000, 1.0.2+0 -> 10_002_000, 1.1.0+0 -> 10_100_000.
        val v = (flutter.versionName ?: "0.0.0").split(".")
        val major = v.getOrNull(0)?.toIntOrNull() ?: 0
        val minor = v.getOrNull(1)?.toIntOrNull() ?: 0
        val patch = v.getOrNull(2)?.toIntOrNull() ?: 0
        versionCode = major * 10_000_000 + minor * 100_000 + patch * 1_000 + flutter.versionCode
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the dedicated release keystore when key.properties is
            // present so installs are stable, in-place updates keep app data
            // (accounts, download history, settings), and the app is Play-ready.
            // Falls back to the debug key when the keystore isn't configured.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
