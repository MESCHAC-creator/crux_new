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
    id("dev.flutter.flutter-plugin-loader") version "1.0.0" // INDISPENSABLE : Répare l'erreur "package does not exist"
    id("dev.flutter.flutter-gradle-plugin") apply false
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")

// Définition globale requise pour le plugin app_links
rootProject.extra.set("compileSdkVersion", 35)
rootProject.extra.set("minSdkVersion", 24)
rootProject.extra.set("targetSdkVersion", 34)

gradle.lifecycle.beforeProject {
    repositories {
        google()
        mavenCentral()
    }
}
