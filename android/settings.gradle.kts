pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        properties.getProperty("flutter.sdk") ?: error("flutter.sdk non défini dans local.properties")
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    // Le "apply false" est remis ici pour corriger l'erreur de la ligne 17 👇
    id("dev.flutter.flutter-gradle-plugin") version "1.0.0" apply false
    id("com.android.application") version "8.2.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
    id("com.google.gms.google-services") version "4.4.1" apply false
}

include(":app")

// 👇 SCRIPT DE SÉCURITÉ : Force Codemagic à détecter et inclure tes plugins Flutter 👇
val flutterProjectRoot = rootDir.parentFile
val pluginsFile = File(flutterProjectRoot, ".flutter-plugins")
if (pluginsFile.exists()) {
    pluginsFile.forEachLine { line ->
        val parts = line.split("=")
        if (parts.size == 2) {
            val pluginName = parts[0]
            val pluginPath = parts[1]
            include(":$pluginName")
            project(":$pluginName").projectDir = File(pluginPath, "android")
        }
    }
}
