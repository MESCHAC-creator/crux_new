plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services") // Requis pour ton architecture Firebase
}

android {
    namespace = "com.example.crux"
    compileSdk = 34

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.crux"
        // minSdk 24 obligatoire pour livekit_client et flutter_webrtc
        minSdk = 24 
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
        
        // MultiDex empêche le crash lié à la tonne de fonctions de Firebase + LiveKit
        multiDexEnabled = true 
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
}
