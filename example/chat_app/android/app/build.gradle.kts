plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.llamadart_chat_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    // The maintained bundle builder provides an isolated, verified staging tree.
    val npuStage = System.getenv("LLAMADART_VALIDATION_NPU_STAGE")
    if (npuStage != null) {
        sourceSets.getByName("main") {
            assets.srcDir("$npuStage/assets")
            jniLibs.srcDir("$npuStage/jniLibs")
            manifest.srcFile("$npuStage/AndroidManifest.xml")
        }
        packaging.jniLibs.useLegacyPackaging = true
        packaging.jniLibs.keepDebugSymbols += setOf(
            "**/libLiteRtDispatch_*.so", "**/libLlamadartVendor_*.so", "**/libQnn*.so",
        )
        androidResources.noCompress += "litertlm"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.llamadart_chat_example"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Match the integration_test plugin bundled with the pinned Flutter SDK.
dependencies {
    androidTestImplementation("androidx.test:runner:1.3.0")
    androidTestImplementation("androidx.test:rules:1.2.0")
}
