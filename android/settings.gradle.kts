pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").let { if (it.exists()) it.inputStream().use { properties.load(it) } }
        properties.getProperty("flutter.sdk") ?: System.getenv("FLUTTER_ROOT") ?: System.getenv("FLUTTER_SDK")
        ?: throw GradleException("Flutter SDK not found.")
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-gradle-plugin") version "1.0.0" apply false
    id("com.android.application") version "8.1.0" apply false
    id("org.jetbrains.kotlin.android") version "1.8.22" apply false
    id("com.google.gms.google-services") version "4.3.15" apply false
}

include(":app")

// Manual plugin loading (fallback)
val flutterProjectRoot = rootProject.projectDir.parentFile
val pluginsFile = File(flutterProjectRoot, ".flutter-plugins")
if (pluginsFile.exists()) {
    pluginsFile.readLines().forEach { line ->
        val parts = line.split("=")
        if (parts.size == 2) {
            val pluginName = parts[0]
            val pluginPath = parts[1]
            val pluginAndroidPath = File(pluginPath, "android")
            if (pluginAndroidPath.exists()) {
                include(":$pluginName")
                project(":$pluginName").projectDir = pluginAndroidPath
            }
        }
    }
}
