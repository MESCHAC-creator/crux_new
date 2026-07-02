    buildTypes {
        getByName("release") {
            isMinifyEnabled = false      // Désactive l'optimisation du code
            isShrinkResources = false    // <-- AJOUTE CETTE LIGNE pour corriger l'erreur !
            
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
