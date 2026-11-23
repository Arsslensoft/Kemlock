import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key, from android/key.properties (kept out of git): storeFile, storePassword,
// keyAlias and keyPassword. A relative storeFile is read from android/.
val releaseKey = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

// Signing a release with the debug key, for `flutter run --release` on a phone at hand only:
// -Pkemlock.signReleaseWithDebugKey=true, or that line in ~/.gradle/gradle.properties.
val signReleaseWithDebugKey = providers.gradleProperty("kemlock.signReleaseWithDebugKey").orNull == "true"

android {
    // The same id as the Capacitor app, so this ships as an update to the same store listing.
    namespace = "com.kemlock.app"
    // 37 for flutter_local_notifications, which schedules the key reminders.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications reads java.time on Android 7, which needs desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The OpenPGP API's IOpenPgpService2.aidl, which mail apps bind to (src/main/aidl, openspec:
    // add-pgp-mail-provider).
    buildFeatures {
        aidl = true
    }

    defaultConfig {
        applicationId = "com.kemlock.app"
        minSdk = 24
        targetSdk = 36
        // From pubspec.yaml's version; the build number is above the last Capacitor build's versionCode.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!releaseKey.isEmpty) {
            create("release") {
                storeFile = rootProject.file(releaseKey.getProperty("storeFile"))
                storePassword = releaseKey.getProperty("storePassword")
                keyAlias = releaseKey.getProperty("keyAlias")
                keyPassword = releaseKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Never the debug key by default: it sits in ~/.android/debug.keystore under the
            // well-known password "android", and a phone takes any update signed with it as
            // coming from us. Without a release key and without the opt-in above, a release
            // build comes out unsigned.
            signingConfig = when {
                !releaseKey.isEmpty -> signingConfigs.getByName("release")
                signReleaseWithDebugKey -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
}

gradle.taskGraph.whenReady {
    if (releaseKey.isEmpty && allTasks.any { it.project == project && it.name.endsWith("Release") }) {
        logger.warn(
            if (signReleaseWithDebugKey) {
                "Kemlock: this release is signed with the DEBUG key (kemlock.signReleaseWithDebugKey). Never distribute it."
            } else {
                "Kemlock: android/key.properties is missing, so this release build is unsigned."
            },
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // local_auth's biometric prompt needs an AppCompat activity theme, or it crashes on Android 8 and below.
    implementation("androidx.appcompat:appcompat:1.7.1")
    // Autofill: the biometric prompt of the fill screen, and the keyboard's inline suggestions.
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.autofill:autofill:1.3.0")
    // The passkey provider: Credential Manager's provider service and requests, from Android 14.
    implementation("androidx.credentials:credentials:1.6.0")

    testImplementation("junit:junit:4.13.2")
    // The real org.json, which the copy's parsing uses, in place of the Android stubs.
    testImplementation("org.json:json:20260814")
}
