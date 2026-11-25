group = "com.kemlock.unified_push"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.21"
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

android {
    namespace = "com.kemlock.unified_push"
    compileSdk = 37

    defaultConfig {
        minSdk = 24
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
    // The UnifiedPush connector (Apache-2.0, Maven Central), 3.3.6 (18 November 2026), the newest 3.x
    // release: its PushService is the receiving side that 3.x keeps (MessagingReceiver is deprecated), and
    // it does the Web Push keys itself. It needs Tink (Apache-2.0) for them and nothing from Google Play
    // services or Firebase. Never add org.unifiedpush.android:embedded-fcm-distributor: that is the
    // library that pulls Firebase in, and Kemlock has none (owner, 2026-11-22).
    implementation("org.unifiedpush.android:connector:3.3.6")

    testImplementation("junit:junit:4.13.2")
}
