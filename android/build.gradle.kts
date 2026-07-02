allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: File = rootProject.layout.buildDirectory.dir("../../build").get().asFile
rootProject.layout.buildDirectory.set(newBuildDir)

subprojects {
    val newSubprojectBuildDir: File = rootProject.layout.buildDirectory.dir(project.name).get().asFile
    project.layout.buildDirectory.set(newSubprojectBuildDir)
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
