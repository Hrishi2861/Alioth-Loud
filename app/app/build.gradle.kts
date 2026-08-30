plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.f3.aliothloud"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.f3.aliothloud"
        // Android 12+. DynamicsProcessing itself is API 28, but the priv-app
        // permission plumbing and foreground service types below assume 31+.
        minSdk = 31
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        // Only English strings are used, and the module ships this APK to one
        // device family. Dropping the other locales strips most of what makes
        // Material's resources.arsc large.
        resourceConfigurations += setOf("en")
    }

    signingConfigs {
        create("release") {
            // Self-signed. This APK is installed by the Magisk/KSU module into
            // /system/priv-app, not through Play, so the key only needs to be
            // stable across updates. build.sh generates it on first run.
            storeFile = file("../keystore.jks")
            storePassword = "aliothloud"
            keyAlias = "aliothloud"
            keyPassword = "aliothloud"
        }
    }

    buildTypes {
        release {
            // R8 + resource shrinking are ON, and they matter here more than in
            // a normal app: this APK is mounted into /system/priv-app by the
            // module, so its size lands in the flashable zip and in the system
            // overlay on every boot.
            //
            // Measured: unshrunk this build is 9.4 MB, of which 8.2 MB is
            // classes.dex (all of Material + AppCompat + kotlin stdlib) and
            // 0.9 MB is resources.arsc. Almost none of it is reachable -- the UI
            // is a switch, some chips and eight sliders.
            //
            // No reflection is used anywhere in this app, and the View subclasses
            // referenced from activity_main.xml are kept automatically by the
            // keep rules aapt2 generates from merged resources, so shrinking is
            // safe without hand-written rules.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        resources.excludes += setOf("META-INF/*.version", "kotlin/**", "DebugProbesKt.bin")
    }
}

dependencies {
    // Deliberately NOT Compose. This APK is mounted into /system/priv-app by
    // the module, so every megabyte lands in the flashable zip and in the system
    // overlay. Compose would add several MB of runtime to render a switch and
    // eight sliders. Even AppCompat + Material needs R8 to be reasonable here
    // (see buildTypes): 9.4 MB unshrunk.
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.core:core-ktx:1.13.1")
}
