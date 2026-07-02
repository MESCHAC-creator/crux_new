allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 🛠️ SCRIPT DE SÉCURITÉ : Injecte automatiquement les propriétés manquantes dans local.properties
// Cela empêche le plugin 'app_links' de crasher avec l'erreur "substring() on null object"
val localPropertiesFile = file("local.properties")
if (localPropertiesFile.exists()) {
    val content = localPropertiesFile.readText()
    val propertiesToAdd = listOf(
        "flutter.compileSdkVersion=34",
        "flutter.minSdkVersion=21",
        "flutter.targetSdkVersion=34"
    )
    val missingProperties = propertiesToAdd.filter { !content.contains(it.split("=")[0]) }
    if (missingProperties.isNotEmpty()) {
        localPropertiesFile.appendText("\n" + missingProperties.joinToString("\n"))
    }
}

// Sécurité supplémentaire pour les plugins qui lisent via le système global "rootProject.ext"
rootProject.extra.set("compileSdkVersion", 34)
rootProject.extra.set("minSdkVersion", 21)
rootProject.extra.set("targetSdkVersion", 34)
rootProject.extra.set("flutter.compileSdkVersion", 34)
rootProject.extra.set("flutter.minSdkVersion", 21)
rootProject.extra.set("flutter.targetSdkVersion", 34)

rootProject.layout.buildDirectory.value(rootProject.projectDir.resolve("../build"))

subprojects {
    project.layout.buildDirectory.value(rootProject.layout.buildDirectory.dir(project.name))
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
