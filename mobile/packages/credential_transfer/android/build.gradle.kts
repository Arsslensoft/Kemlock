// `java` alone names Gradle's java extension inside a build script, so the package is imported
import java.util.Base64

group = "com.kemlock.credential_transfer"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Whether the exported activity exists at all (plan add-credential-exchange, task 8.6), read from the very define that
// switches the Dart side on, `--dart-define=KEMLOCK_CREDENTIAL_EXPORT=true`, so the two halves can't disagree. Flutter's
// tool passes the defines to Gradle as the property `dart-defines`: KEY=VALUE pairs, each base64, joined by commas. As
// in Dart, the last definition of a name wins and only the exact text `true` turns it on; no define, no export.
val credentialExportOn: Boolean = (findProperty("dart-defines") as? String)
    .orEmpty()
    .split(',')
    .mapNotNull { runCatching { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }.getOrNull() }
    .lastOrNull { it.startsWith("KEMLOCK_CREDENTIAL_EXPORT=") } == "KEMLOCK_CREDENTIAL_EXPORT=true"

android {
    namespace = "com.kemlock.credential_transfer"
    compileSdk = 37

    defaultConfig {
        // The libraries' own minimum; the transfer runs from Android 8, which the plugin checks.
        minSdk = 24

        // The manifest's android:enabled for ExportActivity reads it; false unless built with the define above
        resValue("bool", "credential_export_enabled", credentialExportOn.toString())
    }

    buildFeatures {
        // Off by default since AGP 8; the resource above needs it
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    // Credential Manager's provider events, 1.0.0-beta01 (9 September 2026), pinned behind the
    // port: move to 1.0.0 when it ships. The second brings Play services, which is why this
    // plugin is the store build's alone. Both are in this module only, never in the app's build.
    implementation("androidx.credentials.providerevents:providerevents:1.0.0-beta01")
    implementation("androidx.credentials.providerevents:providerevents-play-services:1.0.0-beta01")

    testImplementation("junit:junit:4.13.2")
}
