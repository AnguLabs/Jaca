import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

kotlin {
    androidTarget {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }

    // iosArm64 = devices, iosSimulatorArm64 = Apple-Silicon simulator. iosX64 (the legacy
    // Intel-Mac simulator) is dropped: Lemonade and Compose Multiplatform don't publish
    // iosX64 artifacts, and the strict KMP dependency checker rejects an unresolvable target.
    listOf(iosArm64(), iosSimulatorArm64()).forEach { iosTarget ->
        iosTarget.binaries.framework {
            baseName = "ComposeApp"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.ui)
            implementation(compose.components.resources)
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.lemonade.ui)   // Lemonade design system (KMP)
        }
        androidMain.dependencies {
            implementation(libs.androidx.activity.compose)
            implementation(libs.kotlinx.coroutines.android)
            implementation(projects.companionGrpc) // generated protobuf + gRPC stubs
        }
    }
}

android {
    namespace = "dev.srsouza.jaca"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "dev.srsouza.jaca"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
        // Git commit the APK was built from, so the desktop can detect when a connected
        // device runs an older companion build than the one Jaca bundles. Passed in by
        // scripts/build-mobile.sh (-PcommitHash=...); "dev" for ad-hoc local builds.
        val commitHash = (project.findProperty("commitHash") as String?) ?: "dev"
        buildConfigField("String", "COMMIT_HASH", "\"$commitHash\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
