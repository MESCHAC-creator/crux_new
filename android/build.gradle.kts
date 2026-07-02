allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Variables pour la compatibilité des plugins
rootProject.extra.set("compileSdkVersion", 34)
rootProject.extra.set("minSdkVersion", 21)
rootProject.extra.set("targetSdkVersion", 34)

rootProject.layout.buildDirectory.set(rootProject.layout.projectDirectory.dir("../build"))

subprojects {
    project.layout.buildDirectory.set(rootProject.layout.buildDirectory.dir(project.name))
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
