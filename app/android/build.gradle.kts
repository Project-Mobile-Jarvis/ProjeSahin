allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://alphacephei.com/maven/") } // vosk aar (vosk_flutter_2)
    }
}

// Eski plugin'ler (vosk_flutter_2) android.namespace belirtmiyor; AGP 8 zorunlu kılıyor.
// Manifest'teki package değerini namespace olarak ata (repo'da kalıcı workaround).
subprojects {
    afterEvaluate {
        val ext = project.extensions.findByName("android")
        if (ext is com.android.build.gradle.BaseExtension && ext.namespace == null) {
            val mf = file("src/main/AndroidManifest.xml")
            if (mf.exists()) {
                Regex("package=\"(.+?)\"")
                    .find(mf.readText())
                    ?.groupValues
                    ?.get(1)
                    ?.let { ext.namespace = it }
            }
        }
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
