# The separate test APK calls these SDK classes by their original names.
# App-only R8 cannot see those calls when the release app is built first.
-keep class dev.flutter.plugins.integration_test.** { *; }

# integration_test exports the framework on the app classpath, so AGP omits
# those dependencies from the separate test APK. Its manifest and reflective
# @RunWith/@Rule entry points are invisible to app-only shrinking.
-keep class androidx.test.runner.AndroidJUnitRunner { *; }
-keep class androidx.test.rule.ActivityTestRule { *; }
-keep class androidx.test.platform.app.InstrumentationRegistry { *; }
-keep @interface org.junit.runner.RunWith { *; }
-keep @interface org.junit.Rule { *; }
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault
