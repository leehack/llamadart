import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun resolveSigningValue(propKey: String, envKey: String): String? {
    val fromProps = keystoreProperties.getProperty(propKey)?.trim()
    if (!fromProps.isNullOrEmpty()) return fromProps
    val fromEnv = System.getenv(envKey)?.trim()
    return if (!fromEnv.isNullOrEmpty()) fromEnv else null
}

val releaseStoreFilePath = resolveSigningValue("storeFile", "STUDIO_KEYSTORE_PATH")
val releaseStorePassword = resolveSigningValue("storePassword", "STUDIO_KEYSTORE_PASSWORD")
val releaseKeyAlias = resolveSigningValue("keyAlias", "STUDIO_KEY_ALIAS")
val releaseKeyPassword = resolveSigningValue("keyPassword", "STUDIO_KEY_PASSWORD")
val hasReleaseKeystore = releaseStoreFilePath != null &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    rootProject.file(releaseStoreFilePath).exists()

android {
    namespace = "dev.llamadart.studio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"
    val qualificationStage = System.getenv("LLAMADART_ANDROID_QUALIFICATION_STAGE")
    if (qualificationStage != null) {
        sourceSets.getByName("main") {
            assets.srcDir("$qualificationStage/assets")
            jniLibs.srcDir("$qualificationStage/jniLibs")
        }
        // The owned PIE must be executable in nativeLibraryDir, and all paths
        // must retain the exact admitted archive bytes for native/public pairing.
        packaging.jniLibs.useLegacyPackaging = true
        packaging.jniLibs.keepDebugSymbols += "**/*.so"
    }
    val consumerProfileStage = System.getenv("LLAMADART_ANDROID_CONSUMER_PROFILE_STAGE")
    if (consumerProfileStage != null) {
        sourceSets.getByName("main").assets.srcDir("$consumerProfileStage/assets")
        packaging.jniLibs.useLegacyPackaging = true
        packaging.jniLibs.keepDebugSymbols += "**/*.so"
        testBuildType = "release"
        buildTypes.getByName("release").proguardFiles("consumer-profile-proguard-rules.pro")
    }
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

    defaultConfig {
        applicationId = "dev.llamadart.studio"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
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
