allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 1. Configuration des variables globales au format attendu par les plugins
rootProject.extra.set("compileSdkVersion", 34)
rootProject.extra.set("minSdkVersion", 21)
rootProject.extra.set("targetSdkVersion", 34)

// Cet objet simule l'ancienne structure Flutter pour les plugins qui font "rootProject.ext.flutter"
rootProject.extra.set("flutter", mapOf(
    "compileSdkVersion" to 34,
    "minSdkVersion" to 21,
    "targetSdkVersion" to 34
))

// ✅ CORRECTION : Utilisation de .set() et .projectDirectory.dir() pour respecter le type "Directory" de Gradle 8+
rootProject.layout.buildDirectory.set(rootProject.layout.projectDirectory.dir("../build"))

subprojects {
    // ✅ CORRECTION : Idem ici, utilisation de .set() pour la cohérence
    project.layout.buildDirectory.set(rootProject.layout.buildDirectory.dir(project.name))
    
    // 2. Injection dynamique pour les plugins qui cherchent "android.flutter" (comme app_links)
    plugins.withId("com.android.library") {
        (extensions.findByName("android") as? org.gradle.api.plugins.ExtensionAware)?.apply {
            extra.set("flutter", mapOf(
                "compileSdkVersion" to 34,
                "minSdkVersion" to 21,
                "targetSdkVersion" to 34
            ))
        }
    }
    
    plugins.withId("com.android.application") {
        (extensions.findByName("android") as? org.gradle.api.plugins.ExtensionAware)?.apply {
            extra.set("flutter", mapOf(
                "compileSdkVersion" to 34,
                "minSdkVersion" to 21,
                "targetSdkVersion" to 34
            ))
        }
    }

    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
