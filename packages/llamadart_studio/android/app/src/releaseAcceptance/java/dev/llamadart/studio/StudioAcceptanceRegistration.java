package dev.llamadart.studio;

import dev.flutter.plugins.integration_test.IntegrationTestPlugin;
import io.flutter.embedding.engine.FlutterEngine;

// Register before Dart starts so even an early fixture failure reaches the runner.
final class StudioAcceptanceRegistration {
    static void registerWith(FlutterEngine engine) {
        if (!engine.getPlugins().has(IntegrationTestPlugin.class)) {
            engine.getPlugins().add(new IntegrationTestPlugin());
        }
    }
}
