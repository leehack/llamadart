# The separate test APK calls these SDK classes by their original names.
# App-only R8 cannot see those calls when the release app is built first.
-keep class dev.flutter.plugins.integration_test.** { *; }
