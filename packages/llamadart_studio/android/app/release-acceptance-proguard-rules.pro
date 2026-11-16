# The separate instrumentation APK references the SDK runner and its shared
# completion future. App-only R8 cannot see those references.
-keep class dev.flutter.plugins.integration_test.** { *; }
-keep class androidx.test.runner.AndroidJUnitRunner { *; }
-keep class androidx.test.rule.ActivityTestRule { *; }
-keep class androidx.test.platform.app.InstrumentationRegistry { *; }
-keep @interface org.junit.runner.RunWith { *; }
-keep @interface org.junit.Rule { *; }
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault

# Retain the engine hook for artifact-level registration verification.
-keepclassmembers class dev.llamadart.studio.MainActivity {
    public void configureFlutterEngine(io.flutter.embedding.engine.FlutterEngine);
}
