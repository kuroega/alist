plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val backendOutput = layout.buildDirectory.dir("generated/backend-jniLibs")

android {
    namespace = "com.alist.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.alist.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(backendOutput)
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libalist.so"
        }
    }
}

dependencies {
    implementation(kotlin("stdlib"))
}

val prepareBackend = tasks.register("prepareBackend") {
    val outputDirectory = backendOutput.get().asFile
    outputs.dir(outputDirectory)

    doLast {
        val requestedBackendDirectory = providers.gradleProperty("backendDir").orNull
        if (requestedBackendDirectory != null) {
            val sourceDirectory = file(requestedBackendDirectory)
            if (!sourceDirectory.isDirectory) {
                throw GradleException("backendDir is not a directory: $sourceDirectory")
            }
            project.delete(outputDirectory)
            project.copy {
                from(sourceDirectory)
                into(outputDirectory)
            }
        } else {
            if (System.getProperty("os.name").lowercase().contains("win")) {
                throw GradleException(
                    "Android backend compilation requires Linux/WSL. " +
                        "Run scripts/build_android_backend.sh in WSL and pass -PbackendDir=<output>."
                )
            }
            val script = rootProject.projectDir.parentFile.resolve("scripts/build_android_backend.sh")
            if (!script.isFile) {
                throw GradleException("Android backend build script not found: $script")
            }
            project.exec {
                commandLine("bash", script.absolutePath, outputDirectory.absolutePath)
            }
        }

        listOf("arm64-v8a", "armeabi-v7a", "x86_64").forEach { abi ->
            val library = outputDirectory.resolve("$abi/libalist.so")
            if (!library.isFile || library.length() == 0L) {
                throw GradleException("Missing Android JNI library for $abi: $library")
            }
        }
    }
}

tasks.named("preBuild") {
    dependsOn(prepareBackend)
}
