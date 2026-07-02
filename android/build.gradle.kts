allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Ces propriétés seront lues par les plugins comme app_links
subprojects {
    project.extra.set("compileSdkVersion", 34)
    project.extra.set("minSdkVersion", 21)
    project.extra.set("targetSdkVersion", 34)
}

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