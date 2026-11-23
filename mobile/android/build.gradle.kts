allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Guava reaches the free build through the camera plugin's CameraX, at 33.5.0-android. GHSA-xxph-c9ww-hj94
// (a deserialization that allocates without a bound) is fixed in 33.7.2, so every project's classpath, the
// plugins' compile classpaths included, takes that version in place of an older one. The request is
// rewritten before Gradle reads its metadata, so the old versions need no entry in verification-metadata.xml.
// A build without Guava, such as the store build's release classpath, gets none.
val guavaFixed = "33.7.2-android"

// True only for a version that parses and is older than the fix: a blank one (a request a BOM or a platform
// leaves to others) and one that doesn't parse are left alone, and a newer one is never taken down.
fun isBelowGuavaFix(version: String): Boolean {
    val fixed = listOf(33, 7, 2)
    if (version.isBlank()) return false
    val parts = version.substringBefore('-').split('.').map { it.toIntOrNull() ?: return false }
    for (i in fixed.indices) {
        val part = parts.getOrElse(i) { 0 }
        if (part != fixed[i]) return part < fixed[i]
    }
    return false
}

subprojects {
    // The classpaths the app and its plugins are compiled and run on, not the build tools' (lint, the Gradle build)
    configurations.matching { it.name.endsWith("CompileClasspath") || it.name.endsWith("RuntimeClasspath") }.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "com.google.guava" && requested.name == "guava" && isBelowGuavaFix(requested.version.orEmpty())) {
                useVersion(guavaFixed)
                because("GHSA-xxph-c9ww-hj94 is fixed in 33.7.2")
            }
        }
    }
}
